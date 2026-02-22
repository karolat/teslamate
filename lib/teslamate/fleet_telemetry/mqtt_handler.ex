defmodule TeslaMate.FleetTelemetry.MqttHandler do
  @moduledoc """
  Tortoise311 handler for fleet telemetry MQTT messages.
  Routes received messages to the Consumer GenServer.
  """

  use Tortoise311.Handler
  require Logger

  defstruct [:consumer]

  @impl true
  def init(opts) do
    {:ok, %__MODULE__{consumer: Keyword.fetch!(opts, :consumer)}}
  end

  @impl true
  def connection(:up, state) do
    Logger.info("Fleet telemetry MQTT connection established")
    {:ok, state}
  end

  def connection(:down, state) do
    Logger.warning("Fleet telemetry MQTT connection dropped")
    {:ok, state}
  end

  def connection(:terminating, state) do
    Logger.warning("Fleet telemetry MQTT connection terminating")
    {:ok, state}
  end

  @impl true
  def handle_message(topic_parts, payload, state) do
    topic = Enum.join(topic_parts, "/")
    GenServer.cast(state.consumer, {:mqtt_message, topic, payload})
    {:ok, state}
  end

  @impl true
  def subscription(:up, topic_filter, state) do
    Logger.info("Fleet telemetry subscribed to: #{topic_filter}")
    {:ok, state}
  end

  def subscription({:warn, _reasons}, topic_filter, state) do
    Logger.warning("Fleet telemetry subscription warning for: #{topic_filter}")
    {:ok, state}
  end

  def subscription({:error, reasons}, topic_filter, state) do
    Logger.error(
      "Fleet telemetry subscription error for #{topic_filter}: #{inspect(reasons)}"
    )

    {:ok, state}
  end

  def subscription(:down, topic_filter, state) do
    Logger.warning("Fleet telemetry subscription down: #{topic_filter}")
    {:ok, state}
  end

  @impl true
  def terminate(reason, _state) do
    Logger.warning("Fleet telemetry MQTT handler terminated: #{inspect(reason)}")
    :ok
  end
end
