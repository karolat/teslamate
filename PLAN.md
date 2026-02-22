# TDD Implementation Plan: Fleet Telemetry Integration (Strategy B — MQTT Bridge)

## Architecture Overview

```
Tesla Vehicle ──[mTLS WebSocket]──▶ Fleet Telemetry Server (Go sidecar)
                                              │
                                       MQTT Dispatcher
                                              │
                                       MQTT Broker (e.g. Mosquitto)
                                              │
                                    TeslaMate subscribes to:
                                      telemetry/{VIN}/v/#
                                      telemetry/{VIN}/connectivity
```

Tesla's Go-based `fleet-telemetry` server receives vehicle data over mTLS WebSockets
and dispatches each field as a separate MQTT message to per-field topics. TeslaMate
subscribes to these topics and feeds the data into its existing vehicle state machine.

### MQTT Topic Format (from fleet-telemetry)

```
{topic_base}/{VIN}/v/{FieldName}     ← vehicle data (one message per field)
{topic_base}/{VIN}/connectivity      ← online/offline status
```

Each payload is JSON-encoded. Numeric fields often arrive as JSON strings (e.g. `"34.797"`).

---

## Phase 1: Field Mapper — Pure Conversion Functions

**Goal:** A stateless module that converts a single Fleet Telemetry field name + JSON value
into the TeslaMate-compatible field name + converted value.

### Files

- `lib/teslamate/fleet_telemetry/field_mapper.ex`
- `test/teslamate/fleet_telemetry/field_mapper_test.exs`

### Test Cases (RED)

```elixir
defmodule TeslaMate.FleetTelemetry.FieldMapperTest do
  use ExUnit.Case, async: true
  alias TeslaMate.FleetTelemetry.FieldMapper

  # --- Unit conversions ---

  test "VehicleSpeed: string mph → integer km/h" do
    assert FieldMapper.map("VehicleSpeed", "34.797") == {:ok, :speed, 56}
  end

  test "VehicleSpeed: zero" do
    assert FieldMapper.map("VehicleSpeed", "0") == {:ok, :speed, 0}
  end

  test "Odometer: string miles → float km" do
    {:ok, :odometer, km} = FieldMapper.map("Odometer", "11270.940")
    assert_in_delta km, 18139.8, 0.1
  end

  test "EstBatteryRange: string miles → Decimal km" do
    {:ok, :est_battery_range_km, km} = FieldMapper.map("EstBatteryRange", "131.519")
    assert Decimal.to_float(km) |> Float.round(1) == 211.7
  end

  test "IdealBatteryRange: string miles → Decimal km" do
    {:ok, :ideal_battery_range_km, km} = FieldMapper.map("IdealBatteryRange", "150.0")
    assert Decimal.to_float(km) |> Float.round(1) == 241.4
  end

  test "RatedRange: string miles → Decimal km" do
    {:ok, :rated_battery_range_km, km} = FieldMapper.map("RatedRange", "200.5")
    assert Decimal.to_float(km) |> Float.round(1) == 322.7
  end

  # --- Direct numeric values ---

  test "BatteryLevel: integer passthrough" do
    assert FieldMapper.map("BatteryLevel", 42) == {:ok, :battery_level, 42}
  end

  test "BatteryLevel: string → integer" do
    assert FieldMapper.map("BatteryLevel", "75") == {:ok, :battery_level, 75}
  end

  test "InsideTemp: string Celsius passthrough" do
    {:ok, :inside_temp, temp} = FieldMapper.map("InsideTemp", "22.5")
    assert Decimal.to_float(temp) == 22.5
  end

  test "OutsideTemp: string Celsius passthrough" do
    {:ok, :outside_temp, temp} = FieldMapper.map("OutsideTemp", "-5.2")
    assert Decimal.to_float(temp) == -5.2
  end

  # --- Location ---

  test "Location: JSON object → latitude + longitude" do
    value = %{"latitude" => 30.2226645, "longitude" => -97.6213806}
    assert FieldMapper.map("Location", value) ==
             {:ok, :location, %{latitude: 30.2226645, longitude: -97.6213806}}
  end

  # --- Shift state enum mapping ---

  test "Gear: ShiftStateD → D" do
    assert FieldMapper.map("Gear", "ShiftStateD") == {:ok, :shift_state, "D"}
  end

  test "Gear: ShiftStateP → P" do
    assert FieldMapper.map("Gear", "ShiftStateP") == {:ok, :shift_state, "P"}
  end

  test "Gear: ShiftStateR → R" do
    assert FieldMapper.map("Gear", "ShiftStateR") == {:ok, :shift_state, "R"}
  end

  test "Gear: ShiftStateN → N" do
    assert FieldMapper.map("Gear", "ShiftStateN") == {:ok, :shift_state, "N"}
  end

  test "Gear: ShiftStateUnknown → nil" do
    assert FieldMapper.map("Gear", "ShiftStateUnknown") == {:ok, :shift_state, nil}
  end

  test "Gear: ShiftStateSNA → nil" do
    assert FieldMapper.map("Gear", "ShiftStateSNA") == {:ok, :shift_state, nil}
  end

  # --- Charging state enum mapping ---

  test "DetailedChargeState: DetailedChargeStateCharging → Charging" do
    assert FieldMapper.map("DetailedChargeState", "DetailedChargeStateCharging") ==
             {:ok, :charging_state, "Charging"}
  end

  test "DetailedChargeState: DetailedChargeStateComplete → Complete" do
    assert FieldMapper.map("DetailedChargeState", "DetailedChargeStateComplete") ==
             {:ok, :charging_state, "Complete"}
  end

  test "DetailedChargeState: DetailedChargeStateDisconnected → Disconnected" do
    assert FieldMapper.map("DetailedChargeState", "DetailedChargeStateDisconnected") ==
             {:ok, :charging_state, "Disconnected"}
  end

  test "DetailedChargeState: DetailedChargeStateStopped → Stopped" do
    assert FieldMapper.map("DetailedChargeState", "DetailedChargeStateStopped") ==
             {:ok, :charging_state, "Stopped"}
  end

  test "DetailedChargeState: DetailedChargeStateNoPower → NoPower" do
    assert FieldMapper.map("DetailedChargeState", "DetailedChargeStateNoPower") ==
             {:ok, :charging_state, "NoPower"}
  end

  test "DetailedChargeState: DetailedChargeStateStarting → Starting" do
    assert FieldMapper.map("DetailedChargeState", "DetailedChargeStateStarting") ==
             {:ok, :charging_state, "Starting"}
  end

  # --- Power computation ---

  test "PackVoltage: stores raw for later computation" do
    assert FieldMapper.map("PackVoltage", "395.2") == {:ok, :pack_voltage, 395.2}
  end

  test "PackCurrent: stores raw for later computation" do
    assert FieldMapper.map("PackCurrent", "-12.5") == {:ok, :pack_current, -12.5}
  end

  # --- Charge fields ---

  test "DCChargingPower: string kW → integer" do
    assert FieldMapper.map("DCChargingPower", "48.7") == {:ok, :charger_power, 49}
  end

  test "ACChargingPower: string kW → integer" do
    assert FieldMapper.map("ACChargingPower", "7.2") == {:ok, :charger_power, 7}
  end

  test "DCChargingEnergyIn: string kWh → Decimal" do
    {:ok, :charge_energy_added, val} = FieldMapper.map("DCChargingEnergyIn", "25.3")
    assert Decimal.to_float(val) == 25.3
  end

  test "ACChargingEnergyIn: string kWh → Decimal" do
    {:ok, :charge_energy_added, val} = FieldMapper.map("ACChargingEnergyIn", "12.1")
    assert Decimal.to_float(val) == 12.1
  end

  test "ChargerVoltage: string → integer" do
    assert FieldMapper.map("ChargerVoltage", "240") == {:ok, :charger_voltage, 240}
  end

  test "ChargeAmps: string → integer" do
    assert FieldMapper.map("ChargeAmps", "32") == {:ok, :charger_actual_current, 32}
  end

  test "ChargeLimitSoc: string → integer" do
    assert FieldMapper.map("ChargeLimitSoc", "80") == {:ok, :charge_limit_soc, 80}
  end

  test "TimeToFullCharge: string hours → float" do
    assert FieldMapper.map("TimeToFullCharge", "1.25") == {:ok, :time_to_full_charge, 1.25}
  end

  test "FastChargerPresent: boolean passthrough" do
    assert FieldMapper.map("FastChargerPresent", true) == {:ok, :fast_charger_present, true}
  end

  test "FastChargerType: enum string passthrough" do
    assert FieldMapper.map("FastChargerType", "Tesla") == {:ok, :fast_charger_type, "Tesla"}
  end

  test "ChargingCableType: string passthrough" do
    assert FieldMapper.map("ChargingCableType", "IEC") == {:ok, :conn_charge_cable, "IEC"}
  end

  # --- Door state ---

  test "DoorState: JSON object → individual booleans" do
    value = %{
      "DriverFront" => true, "PassengerFront" => false,
      "DriverRear" => false, "PassengerRear" => false,
      "TrunkFront" => false, "TrunkRear" => true
    }
    assert FieldMapper.map("DoorState", value) == {:ok, :doors, %{
      df: true, pf: false, dr: false, pr: false, ft: false, rt: true
    }}
  end

  # --- Window state ---

  test "FdWindow: WindowStateOpen → open" do
    assert FieldMapper.map("FdWindow", "WindowStateOpen") == {:ok, :fd_window, :open}
  end

  test "FdWindow: WindowStateClosed → closed" do
    assert FieldMapper.map("FdWindow", "WindowStateClosed") == {:ok, :fd_window, :closed}
  end

  # --- Vehicle state fields ---

  test "Locked: boolean passthrough" do
    assert FieldMapper.map("Locked", true) == {:ok, :locked, true}
  end

  test "SentryModeState: enum → boolean" do
    assert FieldMapper.map("SentryModeState", "SentryModeStateOn") == {:ok, :sentry_mode, true}
    assert FieldMapper.map("SentryModeState", "SentryModeStateOff") == {:ok, :sentry_mode, false}
  end

  test "Version: string passthrough" do
    assert FieldMapper.map("Version", "2024.8.9 abc123") == {:ok, :car_version, "2024.8.9 abc123"}
  end

  test "VehicleName: string passthrough" do
    assert FieldMapper.map("VehicleName", "My Tesla") == {:ok, :display_name, "My Tesla"}
  end

  test "IsUserPresent: boolean passthrough" do
    assert FieldMapper.map("IsUserPresent", true) == {:ok, :is_user_present, true}
  end

  test "CenterDisplayState: integer passthrough" do
    assert FieldMapper.map("CenterDisplayState", 2) == {:ok, :center_display_state, 2}
  end

  # --- TPMS ---

  test "TpmsPressureFl: string → Decimal" do
    {:ok, :tpms_pressure_fl, val} = FieldMapper.map("TpmsPressureFl", "2.9")
    assert Decimal.to_float(val) == 2.9
  end

  test "TpmsPressureFr: string → Decimal" do
    {:ok, :tpms_pressure_fr, val} = FieldMapper.map("TpmsPressureFr", "3.0")
    assert Decimal.to_float(val) == 3.0
  end

  test "TpmsPressureRl: string → Decimal" do
    {:ok, :tpms_pressure_rl, val} = FieldMapper.map("TpmsPressureRl", "3.1")
    assert Decimal.to_float(val) == 3.1
  end

  test "TpmsPressureRr: string → Decimal" do
    {:ok, :tpms_pressure_rr, val} = FieldMapper.map("TpmsPressureRr", "3.2")
    assert Decimal.to_float(val) == 3.2
  end

  # --- GpsHeading ---

  test "GpsHeading: string → integer" do
    assert FieldMapper.map("GpsHeading", "274.5") == {:ok, :heading, 275}
  end

  # --- Unknown fields ---

  test "unknown field returns :ignore" do
    assert FieldMapper.map("SomeUnknownField", "whatever") == :ignore
  end

  # --- Invalid values ---

  test "invalid value (true on numeric field) returns :invalid" do
    assert FieldMapper.map("VehicleSpeed", true) == :invalid
  end
end
```

### Implementation (GREEN)

```elixir
defmodule TeslaMate.FleetTelemetry.FieldMapper do
  @moduledoc """
  Maps a single Fleet Telemetry field name + JSON-decoded value
  to the TeslaMate-compatible field name + converted value.
  """

  alias TeslaMate.Convert

  @miles_to_km 1.60934
  @mph_to_kmh  1.60934

  # Returns {:ok, field_atom, converted_value} | :ignore | :invalid

  def map(field_name, value)

  # --- Speed (mph string → km/h integer) ---
  def map("VehicleSpeed", val) when is_binary(val) do
    case Float.parse(val) do
      {mph, _} -> {:ok, :speed, round(mph * @mph_to_kmh)}
      :error -> :invalid
    end
  end

  # --- Odometer (miles string → km float) ---
  def map("Odometer", val) when is_binary(val) do
    case Float.parse(val) do
      {miles, _} -> {:ok, :odometer, Float.round(miles * @miles_to_km, 6)}
      :error -> :invalid
    end
  end

  # --- Range fields (miles string → km Decimal) ---
  def map("EstBatteryRange", val), do: miles_string_to_km_decimal(:est_battery_range_km, val)
  def map("IdealBatteryRange", val), do: miles_string_to_km_decimal(:ideal_battery_range_km, val)
  def map("RatedRange", val), do: miles_string_to_km_decimal(:rated_battery_range_km, val)

  # --- BatteryLevel (integer or string → integer) ---
  def map("BatteryLevel", val) when is_integer(val), do: {:ok, :battery_level, val}
  def map("BatteryLevel", val) when is_binary(val), do: parse_integer(:battery_level, val)

  # --- Temperature (string Celsius → Decimal) ---
  def map("InsideTemp", val), do: string_to_decimal(:inside_temp, val)
  def map("OutsideTemp", val), do: string_to_decimal(:outside_temp, val)

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
  def map("DetailedChargeState", val) when is_binary(val) do
    state = val
    |> String.replace_leading("DetailedChargeState", "")
    |> case do
      "Unknown" -> nil
      s -> s
    end
    {:ok, :charging_state, state}
  end

  # --- Pack voltage/current (for power computation) ---
  def map("PackVoltage", val), do: parse_float_raw(:pack_voltage, val)
  def map("PackCurrent", val), do: parse_float_raw(:pack_current, val)

  # --- Charger power (DC or AC, string kW → integer) ---
  def map("DCChargingPower", val), do: parse_to_rounded_int(:charger_power, val)
  def map("ACChargingPower", val), do: parse_to_rounded_int(:charger_power, val)

  # --- Charge energy (DC or AC, string kWh → Decimal) ---
  def map("DCChargingEnergyIn", val), do: string_to_decimal(:charge_energy_added, val)
  def map("ACChargingEnergyIn", val), do: string_to_decimal(:charge_energy_added, val)

  # --- Other charge fields ---
  def map("ChargerVoltage", val), do: parse_to_rounded_int(:charger_voltage, val)
  def map("ChargeAmps", val), do: parse_to_rounded_int(:charger_actual_current, val)
  def map("ChargeLimitSoc", val), do: parse_integer(:charge_limit_soc, val)
  def map("TimeToFullCharge", val), do: parse_float_raw(:time_to_full_charge, val)
  def map("FastChargerPresent", val) when is_boolean(val), do: {:ok, :fast_charger_present, val}
  def map("FastChargerType", val) when is_binary(val), do: {:ok, :fast_charger_type, val}
  def map("ChargingCableType", val) when is_binary(val), do: {:ok, :conn_charge_cable, val}

  # --- Door state ---
  def map("DoorState", %{} = val) do
    {:ok, :doors, %{
      df: val["DriverFront"] || false,
      pf: val["PassengerFront"] || false,
      dr: val["DriverRear"] || false,
      pr: val["PassengerRear"] || false,
      ft: val["TrunkFront"] || false,
      rt: val["TrunkRear"] || false
    }}
  end

  # --- Window state ---
  def map(win, val) when win in ~w(FdWindow FpWindow RdWindow RpWindow) do
    key = win |> Macro.underscore() |> String.to_atom()
    state = case val do
      "WindowStateOpen" -> :open
      "WindowStateClosed" -> :closed
      _ -> :unknown
    end
    {:ok, key, state}
  end

  # --- Vehicle state booleans ---
  def map("Locked", val) when is_boolean(val), do: {:ok, :locked, val}
  def map("IsUserPresent", val) when is_boolean(val), do: {:ok, :is_user_present, val}

  # --- Sentry mode ---
  def map("SentryModeState", "SentryModeStateOn"), do: {:ok, :sentry_mode, true}
  def map("SentryModeState", "SentryModeStateOff"), do: {:ok, :sentry_mode, false}
  def map("SentryModeState", _), do: {:ok, :sentry_mode, false}

  # --- String passthrough ---
  def map("Version", val) when is_binary(val), do: {:ok, :car_version, val}
  def map("VehicleName", val) when is_binary(val), do: {:ok, :display_name, val}

  # --- CenterDisplayState ---
  def map("CenterDisplayState", val) when is_integer(val), do: {:ok, :center_display_state, val}

  # --- TPMS ---
  def map("TpmsPressureFl", val), do: string_to_decimal(:tpms_pressure_fl, val)
  def map("TpmsPressureFr", val), do: string_to_decimal(:tpms_pressure_fr, val)
  def map("TpmsPressureRl", val), do: string_to_decimal(:tpms_pressure_rl, val)
  def map("TpmsPressureRr", val), do: string_to_decimal(:tpms_pressure_rr, val)

  # --- GpsHeading ---
  def map("GpsHeading", val), do: parse_to_rounded_int(:heading, val)

  # --- Catch-all ---
  def map(_field, _value), do: :ignore

  # --- Helpers ---

  defp miles_string_to_km_decimal(key, val) when is_binary(val) do
    case Float.parse(val) do
      {miles, _} ->
        km = Decimal.from_float(miles * @miles_to_km)
        {:ok, key, Decimal.round(km, 2)}
      :error -> :invalid
    end
  end
  defp miles_string_to_km_decimal(_key, _val), do: :invalid

  defp string_to_decimal(key, val) when is_binary(val) do
    case Decimal.parse(val) do
      {d, _} -> {:ok, key, d}
      :error -> :invalid
    end
  end
  defp string_to_decimal(_key, _val), do: :invalid

  defp parse_float_raw(key, val) when is_binary(val) do
    case Float.parse(val) do
      {f, _} -> {:ok, key, f}
      :error -> :invalid
    end
  end
  defp parse_float_raw(key, val) when is_number(val), do: {:ok, key, val / 1}
  defp parse_float_raw(_key, _val), do: :invalid

  defp parse_integer(key, val) when is_binary(val) do
    case Integer.parse(val) do
      {i, _} -> {:ok, key, i}
      :error -> :invalid
    end
  end

  defp parse_to_rounded_int(key, val) when is_binary(val) do
    case Float.parse(val) do
      {f, _} -> {:ok, key, round(f)}
      :error -> :invalid
    end
  end
  defp parse_to_rounded_int(key, val) when is_number(val), do: {:ok, key, round(val)}
  defp parse_to_rounded_int(_key, _val), do: :invalid
end
```

---

## Phase 2: Vehicle State Accumulator

**Goal:** A GenServer-like accumulator that receives individual field updates and assembles
them into the `TeslaApi.Vehicle` structs that the existing Vehicle state machine expects.
This bridges the gap between "one MQTT message per field" and the state machine's
expectation of a complete vehicle state snapshot.

### Files

- `lib/teslamate/fleet_telemetry/state_accumulator.ex`
- `test/teslamate/fleet_telemetry/state_accumulator_test.exs`

### Design

The accumulator holds a map of the latest known values for each field. When a new field
arrives, it updates its internal state and, after a short debounce window (configurable,
default 250ms), emits a complete `TeslaApi.Vehicle` struct to the Vehicle state machine
via the same PubSub/callback mechanism the API poller uses.

The debounce is important because fleet-telemetry sends 30+ fields individually — we
don't want to trigger 30 state machine transitions per batch.

### Test Cases (RED)

```elixir
defmodule TeslaMate.FleetTelemetry.StateAccumulatorTest do
  use ExUnit.Case, async: true
  alias TeslaMate.FleetTelemetry.StateAccumulator

  # --- Accumulation ---

  test "accumulates individual fields into state map" do
    acc = StateAccumulator.new()
    acc = StateAccumulator.put(acc, :speed, 56)
    acc = StateAccumulator.put(acc, :battery_level, 75)
    acc = StateAccumulator.put(acc, :location, %{latitude: 30.0, longitude: -97.0})

    assert StateAccumulator.get(acc, :speed) == 56
    assert StateAccumulator.get(acc, :battery_level) == 75
    assert StateAccumulator.get(acc, :location) == %{latitude: 30.0, longitude: -97.0}
  end

  test "later values overwrite earlier values" do
    acc = StateAccumulator.new()
    |> StateAccumulator.put(:speed, 56)
    |> StateAccumulator.put(:speed, 72)

    assert StateAccumulator.get(acc, :speed) == 72
  end

  test "computes power from pack_voltage and pack_current" do
    acc = StateAccumulator.new()
    |> StateAccumulator.put(:pack_voltage, 395.0)
    |> StateAccumulator.put(:pack_current, -25.3)

    # power = 395.0 * -25.3 / 1000 = -9.9965 → round to -10
    assert StateAccumulator.computed_power(acc) == -10
  end

  test "computed_power returns nil when voltage or current missing" do
    acc = StateAccumulator.new()
    |> StateAccumulator.put(:pack_voltage, 395.0)

    assert StateAccumulator.computed_power(acc) == nil
  end

  # --- Conversion to TeslaApi.Vehicle ---

  test "to_vehicle builds a TeslaApi.Vehicle struct" do
    acc = StateAccumulator.new()
    |> StateAccumulator.put(:speed, 56)
    |> StateAccumulator.put(:battery_level, 75)
    |> StateAccumulator.put(:location, %{latitude: 30.0, longitude: -97.0})
    |> StateAccumulator.put(:shift_state, "D")
    |> StateAccumulator.put(:charging_state, "Disconnected")
    |> StateAccumulator.put(:car_version, "2024.8.9 abc")
    |> StateAccumulator.put(:display_name, "My Tesla")

    vehicle = StateAccumulator.to_vehicle(acc, "online")

    assert vehicle.state == "online"
    assert vehicle.display_name == "My Tesla"
    assert vehicle.drive_state.speed == 56
    assert vehicle.drive_state.latitude == 30.0
    assert vehicle.drive_state.longitude == -97.0
    assert vehicle.drive_state.shift_state == "D"
    assert vehicle.charge_state.battery_level == 75
    assert vehicle.charge_state.charging_state == "Disconnected"
    assert vehicle.vehicle_state.car_version == "2024.8.9 abc"
  end

  test "to_vehicle with charging fields" do
    acc = StateAccumulator.new()
    |> StateAccumulator.put(:charging_state, "Charging")
    |> StateAccumulator.put(:charger_power, 48)
    |> StateAccumulator.put(:charger_voltage, 400)
    |> StateAccumulator.put(:charger_actual_current, 120)
    |> StateAccumulator.put(:charge_energy_added, Decimal.new("25.3"))
    |> StateAccumulator.put(:charge_limit_soc, 80)

    vehicle = StateAccumulator.to_vehicle(acc, "online")

    assert vehicle.charge_state.charging_state == "Charging"
    assert vehicle.charge_state.charger_power == 48
    assert vehicle.charge_state.charger_voltage == 400
    assert vehicle.charge_state.charger_actual_current == 120
    assert vehicle.charge_state.charge_energy_added == Decimal.new("25.3")
    assert vehicle.charge_state.charge_limit_soc == 80
  end

  test "to_vehicle includes doors as legacy numeric values" do
    acc = StateAccumulator.new()
    |> StateAccumulator.put(:doors, %{df: true, pf: false, dr: false, pr: false, ft: false, rt: true})

    vehicle = StateAccumulator.to_vehicle(acc, "online")

    assert vehicle.vehicle_state.df == 1
    assert vehicle.vehicle_state.pf == 0
    assert vehicle.vehicle_state.rt == 1
  end

  test "to_vehicle includes window state" do
    acc = StateAccumulator.new()
    |> StateAccumulator.put(:fd_window, :open)
    |> StateAccumulator.put(:fp_window, :closed)
    |> StateAccumulator.put(:rd_window, :closed)
    |> StateAccumulator.put(:rp_window, :closed)

    vehicle = StateAccumulator.to_vehicle(acc, "online")

    assert vehicle.vehicle_state.fd_window == 1
    assert vehicle.vehicle_state.fp_window == 0
  end

  test "to_vehicle computes power when pack_voltage and pack_current present" do
    acc = StateAccumulator.new()
    |> StateAccumulator.put(:pack_voltage, 395.0)
    |> StateAccumulator.put(:pack_current, 25.3)

    vehicle = StateAccumulator.to_vehicle(acc, "online")

    # 395.0 * 25.3 / 1000 ≈ 10
    assert vehicle.drive_state.power == 10
  end

  test "to_vehicle sets timestamp on all sub-states" do
    now = DateTime.utc_now() |> DateTime.to_unix(:millisecond)
    acc = StateAccumulator.new()
    |> StateAccumulator.put_timestamp(now)

    vehicle = StateAccumulator.to_vehicle(acc, "online")

    assert vehicle.drive_state.timestamp == now
    assert vehicle.charge_state.timestamp == now
    assert vehicle.climate_state.timestamp == now
    assert vehicle.vehicle_state.timestamp == now
  end
end
```

### Implementation Sketch (GREEN)

A pure data structure module (no GenServer) with `new/0`, `put/3`, `get/2`,
`to_vehicle/2`, `computed_power/1`, and `put_timestamp/2`.

Internally stores `%{fields: %{}, timestamp: nil}`.

`to_vehicle/2` builds:
```elixir
%TeslaApi.Vehicle{
  state: vehicle_state_string,
  display_name: fields[:display_name],
  drive_state: %TeslaApi.Vehicle.State.Drive{
    timestamp: timestamp,
    latitude: get_in(fields, [:location, :latitude]),
    longitude: get_in(fields, [:location, :longitude]),
    speed: fields[:speed],
    power: computed_power_or_field(fields),
    shift_state: fields[:shift_state],
    heading: fields[:heading]
  },
  charge_state: %TeslaApi.Vehicle.State.Charge{
    timestamp: timestamp,
    battery_level: fields[:battery_level],
    charging_state: fields[:charging_state],
    # ...all charge fields...
  },
  climate_state: %TeslaApi.Vehicle.State.Climate{
    timestamp: timestamp,
    inside_temp: fields[:inside_temp],
    outside_temp: fields[:outside_temp]
  },
  vehicle_state: %TeslaApi.Vehicle.State.VehicleState{
    timestamp: timestamp,
    car_version: fields[:car_version],
    locked: fields[:locked],
    sentry_mode: fields[:sentry_mode],
    # ...door/window fields as 0/1 integers...
  }
}
```

---

## Phase 3: MQTT Consumer (Fleet Telemetry Subscriber)

**Goal:** A GenServer that subscribes to `{topic_base}/{VIN}/v/#` and
`{topic_base}/{VIN}/connectivity` topics on the MQTT broker where fleet-telemetry
publishes, and routes parsed data to the appropriate StateAccumulator/Vehicle.

### Files

- `lib/teslamate/fleet_telemetry/consumer.ex`
- `test/teslamate/fleet_telemetry/consumer_test.exs`

### Design

Uses `Tortoise311` (already a dependency) to subscribe to the MQTT broker.
The consumer:

1. Subscribes to `{topic_base}/+/v/#` (wildcard for all VINs and fields)
2. Subscribes to `{topic_base}/+/connectivity`
3. On each message, extracts VIN and field name from the topic
4. JSON-decodes the payload
5. Passes through FieldMapper
6. Updates the appropriate StateAccumulator (one per VIN, held in a map/ETS)
7. After debounce, emits the accumulated state to the Vehicle GenStateMachine

### Test Cases (RED)

```elixir
defmodule TeslaMate.FleetTelemetry.ConsumerTest do
  use ExUnit.Case, async: true
  alias TeslaMate.FleetTelemetry.Consumer

  # --- Topic parsing ---

  test "parse_topic extracts VIN and field from vehicle data topic" do
    assert Consumer.parse_topic("telemetry/5YJ3E1EA1NF123456/v/VehicleSpeed") ==
             {:ok, "5YJ3E1EA1NF123456", "VehicleSpeed"}
  end

  test "parse_topic extracts VIN from connectivity topic" do
    assert Consumer.parse_topic("telemetry/5YJ3E1EA1NF123456/connectivity") ==
             {:ok, "5YJ3E1EA1NF123456", :connectivity}
  end

  test "parse_topic returns error for unknown topic pattern" do
    assert Consumer.parse_topic("other/topic") == :error
  end

  # --- Payload decoding ---

  test "decode_payload: JSON string" do
    assert Consumer.decode_payload("\"34.797\"") == {:ok, "34.797"}
  end

  test "decode_payload: JSON number" do
    assert Consumer.decode_payload("42") == {:ok, 42}
  end

  test "decode_payload: JSON boolean" do
    assert Consumer.decode_payload("true") == {:ok, true}
  end

  test "decode_payload: JSON object" do
    assert Consumer.decode_payload(~s({"latitude":30.0,"longitude":-97.0})) ==
             {:ok, %{"latitude" => 30.0, "longitude" => -97.0}}
  end

  test "decode_payload: invalid JSON returns error" do
    assert Consumer.decode_payload("not json") == :error
  end

  # --- Integration: message handling ---

  test "handle_message updates accumulator and notifies vehicle" do
    # This test uses a mock vehicle registry to verify that after
    # receiving enough fields, a vehicle update is dispatched.
    # Detailed in Phase 4 integration tests.
  end
end
```

### Implementation Sketch (GREEN)

```elixir
defmodule TeslaMate.FleetTelemetry.Consumer do
  use GenServer
  require Logger

  alias TeslaMate.FleetTelemetry.{FieldMapper, StateAccumulator}

  defstruct [:topic_base, :client_id, :vehicles, :accumulators, :debounce_timers]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def parse_topic(topic) do
    case String.split(topic, "/") do
      [_base, vin, "v", field] -> {:ok, vin, field}
      [_base, vin, "connectivity"] -> {:ok, vin, :connectivity}
      _ -> :error
    end
  end

  def decode_payload(payload) do
    case Jason.decode(payload) do
      {:ok, value} -> {:ok, value}
      {:error, _} -> :error
    end
  end

  # GenServer callbacks handle Tortoise311 messages,
  # debounce timer, and vehicle dispatch.
end
```

### Tortoise311 Handler

Implement `Tortoise311.Handler` behaviour in a separate module:

```elixir
defmodule TeslaMate.FleetTelemetry.MqttHandler do
  @behaviour Tortoise311.Handler

  def init(args) do
    {:ok, args}
  end

  def handle_message(topic_parts, payload, state) do
    topic = Enum.join(topic_parts, "/")
    GenServer.cast(state.consumer_pid, {:mqtt_message, topic, payload})
    {:ok, state}
  end

  # connection_up, connection_down, subscription callbacks...
end
```

---

## Phase 4: Vehicle State Machine Integration

**Goal:** Allow the existing Vehicle GenStateMachine to accept telemetry data
from the Fleet Telemetry consumer as an alternative to the API poller.

### Files Modified

- `lib/teslamate/vehicles/vehicle.ex` (add new event handling)
- `lib/teslamate/vehicles/vehicle/summary.ex` (no changes needed — already reads from state)
- `lib/teslamate/vehicles.ex` (add fleet telemetry mode toggle)

### Files Added

- `test/teslamate/fleet_telemetry/integration_test.exs`

### Design Decision: Dual-Mode Operation

Rather than replacing the API poller entirely, we add a **parallel data path**:

```
                     ┌─── API Poller (existing) ────┐
                     │                               │
Vehicle GenStateMachine ◄──────────────────────────────┤
                     │                               │
                     └─── Fleet Telemetry Consumer ──┘
```

When fleet telemetry is enabled for a VIN:
1. The API poller's poll interval is extended to 5+ minutes (fallback/health check only)
2. Fleet Telemetry data drives state transitions in real-time
3. The state machine receives the same `TeslaApi.Vehicle` struct from both paths

This is achieved by having the Consumer call the same
`Vehicle.handle_cast({:api_result, vehicle_data}, state)` path
that the API poller uses, or by introducing a new
`{:fleet_telemetry_update, vehicle_data}` event that delegates to the same
internal handling logic.

### Test Cases (RED)

```elixir
defmodule TeslaMate.FleetTelemetry.IntegrationTest do
  use TeslaMate.VehicleCase, async: true

  # Test that the Vehicle state machine correctly processes a
  # TeslaApi.Vehicle struct assembled from Fleet Telemetry data.

  test "fleet telemetry data drives state to :online" do
    # Build a TeslaApi.Vehicle struct via StateAccumulator
    # (simulating what the Consumer would produce)
    # Send it to the Vehicle GenStateMachine
    # Assert state transitions to :online
  end

  test "fleet telemetry driving data creates a drive session" do
    # Send a sequence of states with shift_state="D" and speed > 0
    # Assert a drive session is created in the log
  end

  test "fleet telemetry charging data creates a charging process" do
    # Send a sequence of states with charging_state="Charging"
    # Assert a charging process is created
  end

  test "fleet telemetry connectivity loss triggers :offline handling" do
    # Send a connectivity message indicating the vehicle went offline
    # Assert the state machine handles it (suspends, etc.)
  end

  test "fleet telemetry and API poller coexist without conflicts" do
    # Verify that receiving data from both sources doesn't cause
    # duplicate log entries or state machine confusion
  end
end
```

### Implementation Plan

1. Add a `:fleet_telemetry_update` event handler in `Vehicle` that:
   - Validates the incoming `TeslaApi.Vehicle` struct
   - Delegates to the existing `handle_event` logic for the current state
   - Resets the API poll timer to a longer interval

2. Add a `fleet_telemetry_enabled?` flag to the Vehicle's state data,
   controlled by configuration.

3. When fleet telemetry is active, the periodic API poll switches to a
   "heartbeat" mode (every 5 minutes) to:
   - Verify the vehicle is still reachable
   - Fetch fields not available via fleet telemetry (e.g., `vehicle_config`)
   - Act as a fallback if fleet telemetry connection drops

---

## Phase 5: Configuration & Environment Variables

### Files Modified

- `config/runtime.exs`
- `lib/teslamate/application.ex`

### New Environment Variables

| Variable | Default | Description |
|---|---|---|
| `FLEET_TELEMETRY_ENABLED` | `"false"` | Enable fleet telemetry MQTT consumer |
| `FLEET_TELEMETRY_MQTT_HOST` | (uses `MQTT_HOST`) | MQTT broker host for fleet telemetry data |
| `FLEET_TELEMETRY_MQTT_PORT` | (uses `MQTT_PORT`) | MQTT broker port for fleet telemetry data |
| `FLEET_TELEMETRY_MQTT_USERNAME` | (uses `MQTT_USERNAME`) | MQTT auth username |
| `FLEET_TELEMETRY_MQTT_PASSWORD` | (uses `MQTT_PASSWORD`) | MQTT auth password |
| `FLEET_TELEMETRY_TOPIC_BASE` | `"telemetry"` | Base topic prefix fleet-telemetry publishes to |
| `FLEET_TELEMETRY_DEBOUNCE_MS` | `"250"` | Debounce window before emitting accumulated state |

### Config Addition (runtime.exs)

```elixir
if System.get_env("FLEET_TELEMETRY_ENABLED") == "true" do
  mqtt_host = System.get_env("FLEET_TELEMETRY_MQTT_HOST") ||
              System.get_env("MQTT_HOST", "localhost")

  config :teslamate, :fleet_telemetry,
    mqtt_host: mqtt_host,
    mqtt_port: (System.get_env("FLEET_TELEMETRY_MQTT_PORT") ||
                System.get_env("MQTT_PORT", "1883")) |> String.to_integer(),
    mqtt_username: System.get_env("FLEET_TELEMETRY_MQTT_USERNAME") ||
                   System.get_env("MQTT_USERNAME"),
    mqtt_password: System.get_env("FLEET_TELEMETRY_MQTT_PASSWORD") ||
                   System.get_env("MQTT_PASSWORD"),
    topic_base: System.get_env("FLEET_TELEMETRY_TOPIC_BASE", "telemetry"),
    debounce_ms: System.get_env("FLEET_TELEMETRY_DEBOUNCE_MS", "250") |> String.to_integer()
end
```

### Application Supervision Tree Addition

```elixir
# In children/0, after TeslaMate.Vehicles:
ft_config = Application.get_env(:teslamate, :fleet_telemetry)
...
if(ft_config != nil, do: {TeslaMate.FleetTelemetry.Consumer, ft_config}),
```

### Test Cases

```elixir
defmodule TeslaMate.FleetTelemetry.ConfigTest do
  use ExUnit.Case, async: true

  test "consumer is not started when FLEET_TELEMETRY_ENABLED is not set" do
    # Verify the consumer process is not in the supervision tree
    assert Process.whereis(TeslaMate.FleetTelemetry.Consumer) == nil
  end
end
```

---

## Phase 6: Database Migration (Optional New Fields)

**Goal:** Add columns for data available from Fleet Telemetry that TeslaMate
doesn't currently store. This phase is **optional** for the initial implementation
and can be deferred.

### Potential New Fields

| Table | Column | Type | Source |
|---|---|---|---|
| `positions` | `pack_voltage` | `:float` | `PackVoltage` |
| `positions` | `pack_current` | `:float` | `PackCurrent` |

### Migration

```elixir
defmodule TeslaMate.Repo.Migrations.AddFleetTelemetryFields do
  use Ecto.Migration

  def change do
    alter table(:positions) do
      add :pack_voltage, :float
      add :pack_current, :float
    end
  end
end
```

This migration is safe to run in production (adding nullable columns is non-blocking).

---

## Implementation Order & TDD Cycle Summary

### Step 1: Phase 1 — FieldMapper (RED → GREEN → REFACTOR)
1. Create `test/teslamate/fleet_telemetry/field_mapper_test.exs` with all test cases
2. Run tests — all fail (RED)
3. Create `lib/teslamate/fleet_telemetry/field_mapper.ex` with implementation
4. Run tests — all pass (GREEN)
5. Refactor: extract shared helpers, ensure `Convert` module is reused where possible

### Step 2: Phase 2 — StateAccumulator (RED → GREEN → REFACTOR)
1. Create `test/teslamate/fleet_telemetry/state_accumulator_test.exs`
2. Run tests — all fail (RED)
3. Create `lib/teslamate/fleet_telemetry/state_accumulator.ex`
4. Run tests — all pass (GREEN)
5. Refactor

### Step 3: Phase 3 — Consumer (RED → GREEN → REFACTOR)
1. Create `test/teslamate/fleet_telemetry/consumer_test.exs`
2. Run tests — all fail (RED)
3. Create `lib/teslamate/fleet_telemetry/consumer.ex` and `mqtt_handler.ex`
4. Run tests — all pass (GREEN)
5. Refactor

### Step 4: Phase 4 — Vehicle Integration (RED → GREEN → REFACTOR)
1. Create `test/teslamate/fleet_telemetry/integration_test.exs`
2. Run tests — fail (RED)
3. Modify `lib/teslamate/vehicles/vehicle.ex` to accept fleet telemetry events
4. Run tests — pass (GREEN)
5. Verify existing vehicle tests still pass

### Step 5: Phase 5 — Configuration
1. Add config to `config/runtime.exs`
2. Add consumer to supervision tree in `application.ex`
3. Test startup with and without fleet telemetry enabled

### Step 6: Phase 6 — Migration (optional)
1. Generate migration
2. Update Position schema if new columns added
3. Run migration, verify

### Step 7: Full Integration Test
1. Run entire test suite: `mix test`
2. Verify no regressions in existing tests
3. Verify fleet telemetry tests pass

---

## Risk Mitigation

| Risk | Mitigation |
|---|---|
| Fleet telemetry data arrives out of order | StateAccumulator uses latest-wins; debounce window aggregates |
| MQTT broker down | Tortoise311 auto-reconnects; API poller serves as fallback |
| Field format changes in fleet-telemetry | FieldMapper logs warnings for unknown fields; unknown fields are :ignore'd |
| State machine receives stale data | Timestamps on accumulated state; Vehicle checks timestamp freshness |
| Dual data sources cause duplicate entries | Fleet telemetry mode extends API poll interval; Vehicle deduplicates by timestamp |
| MQTT message flood under heavy driving | Debounce window (250ms default) batches rapid updates |

---

## Testing Strategy

1. **Unit tests** (Phases 1-2): Pure function tests, no external deps, async: true
2. **Integration tests** (Phase 3): Mock MQTT broker using Tortoise311 test helpers
3. **State machine tests** (Phase 4): Use existing VehicleCase infrastructure with mocks
4. **End-to-end tests**: Manual testing with a real fleet-telemetry server + MQTT broker

All tests follow the existing project conventions:
- `use ExUnit.Case, async: true` for pure unit tests
- `use TeslaMate.VehicleCase` for vehicle state machine tests
- `use TeslaMate.DataCase` for database tests
- Mock modules via `{MockModule, mock_name}` dependency injection pattern
