defmodule TeslaMate.FleetTelemetry.StateAccumulator do
  @moduledoc """
  Accumulates individual Fleet Telemetry field updates into a coherent
  `TeslaApi.Vehicle` struct compatible with TeslaMate's vehicle state machine.

  This is a pure data structure (no GenServer). Each `put/3` returns a new
  accumulator with the updated field.
  """

  alias TeslaApi.Vehicle
  alias TeslaApi.Vehicle.State.{Drive, Charge, Climate, VehicleState, VehicleConfig}

  defstruct fields: %{}, timestamp: nil

  @type t :: %__MODULE__{
          fields: map(),
          timestamp: non_neg_integer() | nil
        }

  @doc "Creates a new empty accumulator."
  def new, do: %__MODULE__{}

  @doc "Stores a field value in the accumulator."
  def put(%__MODULE__{} = acc, key, value) do
    %{acc | fields: Map.put(acc.fields, key, value)}
  end

  @doc "Retrieves a field value from the accumulator."
  def get(%__MODULE__{fields: fields}, key) do
    Map.get(fields, key)
  end

  @doc "Stores the timestamp (milliseconds since epoch)."
  def put_timestamp(%__MODULE__{} = acc, ts) do
    %{acc | timestamp: ts}
  end

  @doc "Retrieves the timestamp."
  def get_timestamp(%__MODULE__{timestamp: ts}), do: ts

  @doc """
  Computes power in kW from pack_voltage and pack_current.
  Returns nil if either is missing.
  """
  def computed_power(%__MODULE__{fields: fields}) do
    with voltage when is_number(voltage) <- Map.get(fields, :pack_voltage),
         current when is_number(current) <- Map.get(fields, :pack_current) do
      round(voltage * current / 1000)
    else
      _ -> nil
    end
  end

  @doc """
  Converts the accumulated state into a `TeslaApi.Vehicle` struct.

  The `vehicle_state_string` is typically "online", "asleep", or "offline".

  All values are stored in the same units as the legacy Tesla Owner API
  (mph for speed, miles for distance/range). The existing `create_position/2`
  in the Vehicle state machine handles metric conversion.
  """
  def to_vehicle(%__MODULE__{fields: fields, timestamp: ts}, vehicle_state_string) do
    location = Map.get(fields, :location, %{})
    doors = Map.get(fields, :doors, %{})

    %Vehicle{
      state: vehicle_state_string,
      display_name: fields[:display_name],
      drive_state: %Drive{
        timestamp: ts,
        latitude: location[:latitude],
        longitude: location[:longitude],
        speed: fields[:speed],
        power: computed_power_from(fields),
        shift_state: fields[:shift_state],
        heading: fields[:heading]
      },
      charge_state: %Charge{
        timestamp: ts,
        battery_level: fields[:battery_level],
        charging_state: fields[:charging_state],
        charger_power: fields[:charger_power],
        charger_voltage: fields[:charger_voltage],
        charger_actual_current: fields[:charger_actual_current],
        charge_energy_added: fields[:charge_energy_added],
        charge_limit_soc: fields[:charge_limit_soc],
        time_to_full_charge: fields[:time_to_full_charge],
        fast_charger_present: fields[:fast_charger_present],
        fast_charger_type: fields[:fast_charger_type],
        conn_charge_cable: fields[:conn_charge_cable],
        est_battery_range: fields[:est_battery_range],
        ideal_battery_range: fields[:ideal_battery_range],
        battery_range: fields[:battery_range]
      },
      climate_state: %Climate{
        timestamp: ts,
        inside_temp: fields[:inside_temp],
        outside_temp: fields[:outside_temp],
        climate_keeper_mode: fields[:climate_keeper_mode]
      },
      vehicle_state: %VehicleState{
        timestamp: ts,
        car_version: fields[:car_version],
        locked: fields[:locked],
        sentry_mode: fields[:sentry_mode],
        is_user_present: fields[:is_user_present],
        center_display_state: fields[:center_display_state],
        odometer: fields[:odometer],
        vehicle_name: fields[:display_name],
        df: bool_to_int(doors[:df]),
        pf: bool_to_int(doors[:pf]),
        dr: bool_to_int(doors[:dr]),
        pr: bool_to_int(doors[:pr]),
        ft: bool_to_int(doors[:ft]),
        rt: bool_to_int(doors[:rt]),
        fd_window: window_to_int(fields[:fd_window]),
        fp_window: window_to_int(fields[:fp_window]),
        rd_window: window_to_int(fields[:rd_window]),
        rp_window: window_to_int(fields[:rp_window]),
        tpms_pressure_fl: fields[:tpms_pressure_fl],
        tpms_pressure_fr: fields[:tpms_pressure_fr],
        tpms_pressure_rl: fields[:tpms_pressure_rl],
        tpms_pressure_rr: fields[:tpms_pressure_rr]
      },
      vehicle_config: %VehicleConfig{}
    }
  end

  # --- Private ---

  defp computed_power_from(fields) do
    with voltage when is_number(voltage) <- Map.get(fields, :pack_voltage),
         current when is_number(current) <- Map.get(fields, :pack_current) do
      round(voltage * current / 1000)
    else
      _ -> nil
    end
  end

  defp bool_to_int(true), do: 1
  defp bool_to_int(false), do: 0
  defp bool_to_int(nil), do: nil

  defp window_to_int(:open), do: 1
  defp window_to_int(:closed), do: 0
  defp window_to_int(_), do: nil
end
