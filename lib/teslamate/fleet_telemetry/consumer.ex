defmodule TeslaMate.FleetTelemetry.Consumer do
  @moduledoc """
  Subscribes to the MQTT broker where Tesla's fleet-telemetry server publishes
  vehicle data and routes it to TeslaMate's vehicle state machines.

  Fleet telemetry publishes individual fields as separate MQTT messages to topics:
    {topic_base}/{VIN}/v/{FieldName}
    {topic_base}/{VIN}/connectivity

  This consumer:
  1. Subscribes to all VINs and fields via wildcard topics
  2. Decodes each JSON payload
  3. Maps fields using FieldMapper
  4. Accumulates updates in a per-VIN StateAccumulator
  5. After a debounce window, emits a TeslaApi.Vehicle struct to the vehicle process
  """

  use GenServer
  require Logger

  alias TeslaMate.FleetTelemetry.{FieldMapper, StateAccumulator}
  alias TeslaMate.Log

  defstruct [
    :topic_base,
    :client_id,
    :debounce_ms,
    accumulators: %{},
    debounce_timers: %{},
    vin_to_car_id: %{}
  ]

  @name __MODULE__

  # --- Public API ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  @doc """
  Parses a topic string to extract VIN and field name.

  Returns `{:ok, vin, field_name}`, `{:ok, vin, :connectivity}`, or `:error`.
  """
  def parse_topic(topic_base, topic) when is_binary(topic_base) and is_binary(topic) do
    base_parts = String.split(topic_base, "/")
    topic_parts = String.split(topic, "/")
    base_len = length(base_parts)

    case Enum.drop(topic_parts, base_len) do
      [vin, "v", field] when byte_size(vin) > 0 and byte_size(field) > 0 ->
        {:ok, vin, field}

      [vin, "connectivity"] when byte_size(vin) > 0 ->
        {:ok, vin, :connectivity}

      _ ->
        :error
    end
  end

  @doc """
  Decodes a JSON-encoded MQTT payload.
  """
  def decode_payload(payload) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, value} -> {:ok, value}
      {:error, _} -> :error
    end
  end

  @doc """
  Processes a single MQTT message through the full pipeline:
  parse topic -> decode payload -> map field.

  Returns:
  - `{:ok, vin, field_atom, converted_value}` for valid vehicle data
  - `{:connectivity, vin, value}` for connectivity events
  - `:ignore` for unknown/unmapped fields
  - `:invalid` for type mismatches
  - `:error` for unparseable topics or payloads
  """
  def process_message(topic_base, topic, payload) do
    with {:ok, vin, field_or_connectivity} <- parse_topic(topic_base, topic),
         {:ok, value} <- decode_payload(payload) do
      case field_or_connectivity do
        :connectivity ->
          {:connectivity, vin, value}

        field when is_binary(field) ->
          case FieldMapper.map(field, value) do
            {:ok, mapped_field, mapped_value} ->
              {:ok, vin, mapped_field, mapped_value}

            :ignore ->
              :ignore

            :invalid ->
              :invalid
          end
      end
    else
      :error -> :error
    end
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    topic_base = Keyword.fetch!(opts, :topic_base)
    debounce_ms = Keyword.get(opts, :debounce_ms, 250)
    client_id = generate_client_id()

    state = %__MODULE__{
      topic_base: topic_base,
      client_id: client_id,
      debounce_ms: debounce_ms
    }

    # Build VIN -> car_id lookup from existing cars
    vin_to_car_id = build_vin_lookup()

    mqtt_opts = Keyword.get(opts, :mqtt, [])

    # Start MQTT connection if mqtt opts provided
    if mqtt_opts != [] do
      start_mqtt_connection(client_id, topic_base, mqtt_opts)
    end

    {:ok, %{state | vin_to_car_id: vin_to_car_id}}
  end

  @impl true
  def handle_cast({:mqtt_message, topic, payload}, state) do
    case process_message(state.topic_base, topic, payload) do
      {:ok, vin, field, value} ->
        state = update_accumulator(state, vin, field, value)
        state = schedule_debounce(state, vin)
        {:noreply, state}

      {:connectivity, vin, value} ->
        handle_connectivity(vin, value, state)
        {:noreply, state}

      :ignore ->
        {:noreply, state}

      :invalid ->
        Logger.debug("Invalid value in fleet telemetry message: #{topic}")
        {:noreply, state}

      :error ->
        Logger.warning("Failed to process fleet telemetry message: #{topic}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:debounce_flush, vin}, state) do
    state = flush_accumulator(state, vin)
    timers = Map.delete(state.debounce_timers, vin)
    {:noreply, %{state | debounce_timers: timers}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Private ---

  defp update_accumulator(state, vin, field, value) do
    acc =
      Map.get(state.accumulators, vin, StateAccumulator.new())
      |> StateAccumulator.put(field, value)
      |> StateAccumulator.put_timestamp(DateTime.utc_now() |> DateTime.to_unix(:millisecond))

    %{state | accumulators: Map.put(state.accumulators, vin, acc)}
  end

  defp schedule_debounce(state, vin) do
    case Map.get(state.debounce_timers, vin) do
      nil ->
        timer = Process.send_after(self(), {:debounce_flush, vin}, state.debounce_ms)
        %{state | debounce_timers: Map.put(state.debounce_timers, vin, timer)}

      _existing_timer ->
        # Timer already scheduled, let it fire
        state
    end
  end

  defp flush_accumulator(state, vin) do
    case Map.get(state.accumulators, vin) do
      nil ->
        state

      acc ->
        vehicle = StateAccumulator.to_vehicle(acc, "online")
        dispatch_to_vehicle(vin, vehicle, state)
        state
    end
  end

  defp dispatch_to_vehicle(vin, vehicle, state) do
    case Map.get(state.vin_to_car_id, vin) do
      nil ->
        Logger.warning("Received fleet telemetry for unknown VIN: #{vin}")

      car_id ->
        # Send to the Vehicle GenStateMachine process
        # The process is registered with its car_id as the name
        case GenStateMachine.cast(:"#{car_id}", {:fleet_telemetry_update, vehicle}) do
          :ok -> :ok
          {:error, reason} -> Logger.warning("Failed to dispatch to vehicle #{car_id}: #{inspect(reason)}")
        end
    end
  end

  defp handle_connectivity(vin, status, state) do
    Logger.info("Fleet telemetry connectivity for #{vin}: #{inspect(status)}")

    case {status, Map.get(state.vin_to_car_id, vin)} do
      {_, nil} ->
        Logger.warning("Connectivity event for unknown VIN: #{vin}")

      {"offline", _car_id} ->
        Logger.info("Vehicle #{vin} went offline via fleet telemetry")

      _ ->
        :ok
    end
  end

  defp build_vin_lookup do
    Log.list_cars()
    |> Enum.map(fn car -> {car.vin, car.id} end)
    |> Map.new()
  rescue
    _ -> %{}
  end

  defp start_mqtt_connection(client_id, topic_base, opts) do
    socket_opts =
      if opts[:ipv6],
        do: [:inet6],
        else: []

    server =
      if opts[:tls] do
        {Tortoise311.Transport.SSL,
         host: opts[:host],
         port: opts[:port] || 8883,
         cacertfile: CAStore.file_path(),
         verify: if(opts[:accept_invalid_certs], do: :verify_none, else: :verify_peer),
         opts: socket_opts}
      else
        {Tortoise311.Transport.Tcp,
         host: opts[:host], port: opts[:port] || 1883, opts: socket_opts}
      end

    subscriptions =
      [
        {"#{topic_base}/+/v/#", 1},
        {"#{topic_base}/+/connectivity", 1}
      ]

    config = [
      client_id: client_id,
      user_name: opts[:username],
      password: opts[:password],
      server: server,
      handler: {TeslaMate.FleetTelemetry.MqttHandler, [consumer: self()]},
      subscriptions: subscriptions
    ]

    case Tortoise311.Connection.start_link(config) do
      {:ok, _pid} ->
        Logger.info("Fleet telemetry MQTT connection started (client: #{client_id})")

      {:error, reason} ->
        Logger.error("Failed to start fleet telemetry MQTT connection: #{inspect(reason)}")
    end
  end

  defp generate_client_id do
    "TESLAMATE_FT_" <>
      (:rand.uniform() |> to_string() |> Base.encode16() |> String.slice(0..10))
  end
end
