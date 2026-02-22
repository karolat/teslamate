defmodule TeslaMate.FleetTelemetry.FieldMapper do
  @moduledoc """
  Maps a single Fleet Telemetry field name + JSON-decoded value
  to the TeslaMate-compatible field name + converted value.

  IMPORTANT: Values are kept in the same units as the legacy Tesla Owner API
  (mph for speed, miles for distance/range). The existing Vehicle state machine
  and `create_position/2` handle the metric conversion downstream.

  Returns `{:ok, field_atom, converted_value}`, `:ignore`, or `:invalid`.
  """

  # --- Speed (mph string → rounded integer, stays in mph) ---

  def map("VehicleSpeed", val) when is_binary(val) do
    with {mph, _} <- Float.parse(val) do
      {:ok, :speed, round(mph)}
    else
      :error -> :invalid
    end
  end

  # --- Odometer (miles string → float, stays in miles) ---

  def map("Odometer", val) when is_binary(val) do
    with {miles, _} <- Float.parse(val) do
      {:ok, :odometer, miles}
    else
      :error -> :invalid
    end
  end

  # --- Range fields (miles string → float, stays in miles) ---
  # These map to charge_state field names matching the legacy API

  def map("EstBatteryRange", val), do: parse_float(:est_battery_range, val)
  def map("IdealBatteryRange", val), do: parse_float(:ideal_battery_range, val)
  def map("RatedRange", val), do: parse_float(:battery_range, val)

  # --- BatteryLevel ---

  def map("BatteryLevel", val) when is_integer(val), do: {:ok, :battery_level, val}

  def map("BatteryLevel", val) when is_binary(val) do
    with {i, _} <- Integer.parse(val) do
      {:ok, :battery_level, i}
    else
      :error -> :invalid
    end
  end

  # --- Temperature (string Celsius → float, no conversion needed) ---

  def map("InsideTemp", val), do: parse_float(:inside_temp, val)
  def map("OutsideTemp", val), do: parse_float(:outside_temp, val)

  # --- Location ---

  def map("Location", %{"latitude" => lat, "longitude" => lng})
      when is_number(lat) and is_number(lng) do
    {:ok, :location, %{latitude: lat, longitude: lng}}
  end

  # --- Gear / Shift State ---

  def map("Gear", "ShiftStateD"), do: {:ok, :shift_state, "D"}
  def map("Gear", "ShiftStateR"), do: {:ok, :shift_state, "R"}
  def map("Gear", "ShiftStateN"), do: {:ok, :shift_state, "N"}
  def map("Gear", "ShiftStateP"), do: {:ok, :shift_state, "P"}
  def map("Gear", "ShiftStateUnknown"), do: {:ok, :shift_state, nil}
  def map("Gear", "ShiftStateInvalid"), do: {:ok, :shift_state, nil}
  def map("Gear", "ShiftStateSNA"), do: {:ok, :shift_state, nil}

  # --- DetailedChargeState ---

  def map("DetailedChargeState", "DetailedChargeState" <> rest) do
    case rest do
      "Unknown" -> {:ok, :charging_state, nil}
      state -> {:ok, :charging_state, state}
    end
  end

  # --- Pack voltage/current (for power computation in StateAccumulator) ---

  def map("PackVoltage", val), do: parse_float(:pack_voltage, val)
  def map("PackCurrent", val), do: parse_float(:pack_current, val)

  # --- Charger power (DC or AC, string kW → rounded integer) ---

  def map("DCChargingPower", val), do: parse_to_rounded_int(:charger_power, val)
  def map("ACChargingPower", val), do: parse_to_rounded_int(:charger_power, val)

  # --- Charge energy (DC or AC, string kWh → float) ---

  def map("DCChargingEnergyIn", val), do: parse_float(:charge_energy_added, val)
  def map("ACChargingEnergyIn", val), do: parse_float(:charge_energy_added, val)

  # --- Other charge fields ---

  def map("ChargerVoltage", val), do: parse_to_rounded_int(:charger_voltage, val)
  def map("ChargeAmps", val), do: parse_to_rounded_int(:charger_actual_current, val)

  def map("ChargeLimitSoc", val) when is_binary(val) do
    with {i, _} <- Integer.parse(val) do
      {:ok, :charge_limit_soc, i}
    else
      :error -> :invalid
    end
  end

  def map("ChargeLimitSoc", val) when is_integer(val), do: {:ok, :charge_limit_soc, val}

  def map("TimeToFullCharge", val), do: parse_float(:time_to_full_charge, val)

  def map("FastChargerPresent", val) when is_boolean(val), do: {:ok, :fast_charger_present, val}
  def map("FastChargerType", val) when is_binary(val), do: {:ok, :fast_charger_type, val}
  def map("ChargingCableType", val) when is_binary(val), do: {:ok, :conn_charge_cable, val}

  # --- Door state ---

  def map("DoorState", %{} = val) do
    {:ok, :doors,
     %{
       df: val["DriverFront"] || false,
       pf: val["PassengerFront"] || false,
       dr: val["DriverRear"] || false,
       pr: val["PassengerRear"] || false,
       ft: val["TrunkFront"] || false,
       rt: val["TrunkRear"] || false
     }}
  end

  # --- Window state ---

  def map("FdWindow", val), do: parse_window_state(:fd_window, val)
  def map("FpWindow", val), do: parse_window_state(:fp_window, val)
  def map("RdWindow", val), do: parse_window_state(:rd_window, val)
  def map("RpWindow", val), do: parse_window_state(:rp_window, val)

  # --- Vehicle state booleans ---

  def map("Locked", val) when is_boolean(val), do: {:ok, :locked, val}
  def map("IsUserPresent", val) when is_boolean(val), do: {:ok, :is_user_present, val}

  # --- Sentry mode ---

  def map("SentryModeState", "SentryModeStateOn"), do: {:ok, :sentry_mode, true}
  def map("SentryModeState", _), do: {:ok, :sentry_mode, false}

  # --- String passthrough ---

  def map("Version", val) when is_binary(val), do: {:ok, :car_version, val}
  def map("VehicleName", val) when is_binary(val), do: {:ok, :display_name, val}

  # --- CenterDisplayState ---

  def map("CenterDisplayState", val) when is_integer(val), do: {:ok, :center_display_state, val}

  # --- TPMS (pass through as float) ---

  def map("TpmsPressureFl", val), do: parse_float(:tpms_pressure_fl, val)
  def map("TpmsPressureFr", val), do: parse_float(:tpms_pressure_fr, val)
  def map("TpmsPressureRl", val), do: parse_float(:tpms_pressure_rl, val)
  def map("TpmsPressureRr", val), do: parse_float(:tpms_pressure_rr, val)

  # --- GpsHeading ---

  def map("GpsHeading", val), do: parse_to_rounded_int(:heading, val)

  # --- ClimateKeeperMode ---

  def map("ClimateKeeperMode", val) when is_binary(val), do: {:ok, :climate_keeper_mode, val}

  # --- Catch-all ---

  def map(_field, _value), do: :ignore

  # --- Private helpers ---

  defp parse_float(key, val) when is_binary(val) do
    with {f, _} <- Float.parse(val) do
      {:ok, key, f}
    else
      :error -> :invalid
    end
  end

  defp parse_float(key, val) when is_number(val), do: {:ok, key, val / 1}
  defp parse_float(_key, _val), do: :invalid

  defp parse_to_rounded_int(key, val) when is_binary(val) do
    with {f, _} <- Float.parse(val) do
      {:ok, key, round(f)}
    else
      :error -> :invalid
    end
  end

  defp parse_to_rounded_int(key, val) when is_number(val), do: {:ok, key, round(val)}
  defp parse_to_rounded_int(_key, _val), do: :invalid

  defp parse_window_state(key, "WindowStateOpen"), do: {:ok, key, :open}
  defp parse_window_state(key, "WindowStateClosed"), do: {:ok, key, :closed}
  defp parse_window_state(key, _), do: {:ok, key, :unknown}
end
