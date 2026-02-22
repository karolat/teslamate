defmodule TeslaMate.FleetTelemetry.FieldMapperTest do
  use ExUnit.Case, async: true

  alias TeslaMate.FleetTelemetry.FieldMapper

  # --- Speed: mph string → number (stays in mph for Vehicle struct) ---
  # create_position does Convert.mph_to_kmh, so we keep mph here

  test "VehicleSpeed: string mph to integer mph" do
    assert FieldMapper.map("VehicleSpeed", "34.797") == {:ok, :speed, 35}
  end

  test "VehicleSpeed: zero" do
    assert FieldMapper.map("VehicleSpeed", "0") == {:ok, :speed, 0}
  end

  test "VehicleSpeed: high speed" do
    assert FieldMapper.map("VehicleSpeed", "75.0") == {:ok, :speed, 75}
  end

  # --- Odometer: miles string → float (stays in miles for Vehicle struct) ---
  # create_position does Convert.miles_to_km, so we keep miles here

  test "Odometer: string miles to float miles" do
    {:ok, :odometer, miles} = FieldMapper.map("Odometer", "11270.940")
    assert_in_delta miles, 11270.940, 0.001
  end

  test "Odometer: zero" do
    {:ok, :odometer, miles} = FieldMapper.map("Odometer", "0")
    assert miles == 0.0
  end

  # --- Range fields: miles string → float (stays in miles for Vehicle struct) ---
  # create_position does Convert.miles_to_km, so we keep miles here

  test "EstBatteryRange: string miles to float miles" do
    {:ok, :est_battery_range, miles} = FieldMapper.map("EstBatteryRange", "131.519")
    assert_in_delta miles, 131.519, 0.001
  end

  test "IdealBatteryRange: string miles to float miles" do
    {:ok, :ideal_battery_range, miles} = FieldMapper.map("IdealBatteryRange", "150.0")
    assert_in_delta miles, 150.0, 0.001
  end

  test "RatedRange: string miles to float miles (maps to battery_range)" do
    {:ok, :battery_range, miles} = FieldMapper.map("RatedRange", "200.5")
    assert_in_delta miles, 200.5, 0.001
  end

  # --- BatteryLevel ---

  test "BatteryLevel: integer passthrough" do
    assert FieldMapper.map("BatteryLevel", 42) == {:ok, :battery_level, 42}
  end

  test "BatteryLevel: string to integer" do
    assert FieldMapper.map("BatteryLevel", "75") == {:ok, :battery_level, 75}
  end

  # --- Temperature (string Celsius → float, no conversion needed) ---

  test "InsideTemp: string Celsius to float" do
    {:ok, :inside_temp, temp} = FieldMapper.map("InsideTemp", "22.5")
    assert temp == 22.5
  end

  test "OutsideTemp: string negative Celsius to float" do
    {:ok, :outside_temp, temp} = FieldMapper.map("OutsideTemp", "-5.2")
    assert temp == -5.2
  end

  # --- Location ---

  test "Location: JSON object to latitude/longitude map" do
    value = %{"latitude" => 30.2226645, "longitude" => -97.6213806}

    assert FieldMapper.map("Location", value) ==
             {:ok, :location, %{latitude: 30.2226645, longitude: -97.6213806}}
  end

  # --- Gear / Shift State ---

  test "Gear: ShiftStateD to D" do
    assert FieldMapper.map("Gear", "ShiftStateD") == {:ok, :shift_state, "D"}
  end

  test "Gear: ShiftStateP to P" do
    assert FieldMapper.map("Gear", "ShiftStateP") == {:ok, :shift_state, "P"}
  end

  test "Gear: ShiftStateR to R" do
    assert FieldMapper.map("Gear", "ShiftStateR") == {:ok, :shift_state, "R"}
  end

  test "Gear: ShiftStateN to N" do
    assert FieldMapper.map("Gear", "ShiftStateN") == {:ok, :shift_state, "N"}
  end

  test "Gear: ShiftStateUnknown to nil" do
    assert FieldMapper.map("Gear", "ShiftStateUnknown") == {:ok, :shift_state, nil}
  end

  test "Gear: ShiftStateInvalid to nil" do
    assert FieldMapper.map("Gear", "ShiftStateInvalid") == {:ok, :shift_state, nil}
  end

  test "Gear: ShiftStateSNA to nil" do
    assert FieldMapper.map("Gear", "ShiftStateSNA") == {:ok, :shift_state, nil}
  end

  # --- DetailedChargeState ---

  test "DetailedChargeState: Charging" do
    assert FieldMapper.map("DetailedChargeState", "DetailedChargeStateCharging") ==
             {:ok, :charging_state, "Charging"}
  end

  test "DetailedChargeState: Complete" do
    assert FieldMapper.map("DetailedChargeState", "DetailedChargeStateComplete") ==
             {:ok, :charging_state, "Complete"}
  end

  test "DetailedChargeState: Disconnected" do
    assert FieldMapper.map("DetailedChargeState", "DetailedChargeStateDisconnected") ==
             {:ok, :charging_state, "Disconnected"}
  end

  test "DetailedChargeState: Stopped" do
    assert FieldMapper.map("DetailedChargeState", "DetailedChargeStateStopped") ==
             {:ok, :charging_state, "Stopped"}
  end

  test "DetailedChargeState: NoPower" do
    assert FieldMapper.map("DetailedChargeState", "DetailedChargeStateNoPower") ==
             {:ok, :charging_state, "NoPower"}
  end

  test "DetailedChargeState: Starting" do
    assert FieldMapper.map("DetailedChargeState", "DetailedChargeStateStarting") ==
             {:ok, :charging_state, "Starting"}
  end

  test "DetailedChargeState: Unknown maps to nil" do
    assert FieldMapper.map("DetailedChargeState", "DetailedChargeStateUnknown") ==
             {:ok, :charging_state, nil}
  end

  # --- Pack voltage / current ---

  test "PackVoltage: string to float" do
    assert FieldMapper.map("PackVoltage", "395.2") == {:ok, :pack_voltage, 395.2}
  end

  test "PackCurrent: string negative to float" do
    assert FieldMapper.map("PackCurrent", "-12.5") == {:ok, :pack_current, -12.5}
  end

  # --- Charge power ---

  test "DCChargingPower: string kW to rounded integer" do
    assert FieldMapper.map("DCChargingPower", "48.7") == {:ok, :charger_power, 49}
  end

  test "ACChargingPower: string kW to rounded integer" do
    assert FieldMapper.map("ACChargingPower", "7.2") == {:ok, :charger_power, 7}
  end

  # --- Charge energy ---

  test "DCChargingEnergyIn: string kWh to float" do
    assert FieldMapper.map("DCChargingEnergyIn", "25.3") == {:ok, :charge_energy_added, 25.3}
  end

  test "ACChargingEnergyIn: string kWh to float" do
    assert FieldMapper.map("ACChargingEnergyIn", "12.1") == {:ok, :charge_energy_added, 12.1}
  end

  # --- Other charge fields ---

  test "ChargerVoltage: string to integer" do
    assert FieldMapper.map("ChargerVoltage", "240") == {:ok, :charger_voltage, 240}
  end

  test "ChargeAmps: string to integer" do
    assert FieldMapper.map("ChargeAmps", "32") == {:ok, :charger_actual_current, 32}
  end

  test "ChargeLimitSoc: string to integer" do
    assert FieldMapper.map("ChargeLimitSoc", "80") == {:ok, :charge_limit_soc, 80}
  end

  test "TimeToFullCharge: string hours to float" do
    assert FieldMapper.map("TimeToFullCharge", "1.25") == {:ok, :time_to_full_charge, 1.25}
  end

  test "FastChargerPresent: boolean passthrough" do
    assert FieldMapper.map("FastChargerPresent", true) == {:ok, :fast_charger_present, true}
    assert FieldMapper.map("FastChargerPresent", false) == {:ok, :fast_charger_present, false}
  end

  test "FastChargerType: string passthrough" do
    assert FieldMapper.map("FastChargerType", "Tesla") == {:ok, :fast_charger_type, "Tesla"}
  end

  test "ChargingCableType: string passthrough" do
    assert FieldMapper.map("ChargingCableType", "IEC") == {:ok, :conn_charge_cable, "IEC"}
  end

  # --- Door state ---

  test "DoorState: JSON object to individual boolean map" do
    value = %{
      "DriverFront" => true,
      "PassengerFront" => false,
      "DriverRear" => false,
      "PassengerRear" => false,
      "TrunkFront" => false,
      "TrunkRear" => true
    }

    assert FieldMapper.map("DoorState", value) ==
             {:ok, :doors, %{df: true, pf: false, dr: false, pr: false, ft: false, rt: true}}
  end

  test "DoorState: all closed" do
    value = %{
      "DriverFront" => false,
      "PassengerFront" => false,
      "DriverRear" => false,
      "PassengerRear" => false,
      "TrunkFront" => false,
      "TrunkRear" => false
    }

    assert FieldMapper.map("DoorState", value) ==
             {:ok, :doors, %{df: false, pf: false, dr: false, pr: false, ft: false, rt: false}}
  end

  # --- Window state ---

  test "FdWindow: open" do
    assert FieldMapper.map("FdWindow", "WindowStateOpen") == {:ok, :fd_window, :open}
  end

  test "FdWindow: closed" do
    assert FieldMapper.map("FdWindow", "WindowStateClosed") == {:ok, :fd_window, :closed}
  end

  test "FpWindow: open" do
    assert FieldMapper.map("FpWindow", "WindowStateOpen") == {:ok, :fp_window, :open}
  end

  test "RdWindow: closed" do
    assert FieldMapper.map("RdWindow", "WindowStateClosed") == {:ok, :rd_window, :closed}
  end

  test "RpWindow: open" do
    assert FieldMapper.map("RpWindow", "WindowStateOpen") == {:ok, :rp_window, :open}
  end

  # --- Vehicle state ---

  test "Locked: boolean passthrough" do
    assert FieldMapper.map("Locked", true) == {:ok, :locked, true}
    assert FieldMapper.map("Locked", false) == {:ok, :locked, false}
  end

  test "SentryModeState: on" do
    assert FieldMapper.map("SentryModeState", "SentryModeStateOn") == {:ok, :sentry_mode, true}
  end

  test "SentryModeState: off" do
    assert FieldMapper.map("SentryModeState", "SentryModeStateOff") == {:ok, :sentry_mode, false}
  end

  test "Version: string passthrough" do
    assert FieldMapper.map("Version", "2024.8.9 abc123") ==
             {:ok, :car_version, "2024.8.9 abc123"}
  end

  test "VehicleName: string passthrough" do
    assert FieldMapper.map("VehicleName", "My Tesla") == {:ok, :display_name, "My Tesla"}
  end

  test "IsUserPresent: boolean passthrough" do
    assert FieldMapper.map("IsUserPresent", true) == {:ok, :is_user_present, true}
    assert FieldMapper.map("IsUserPresent", false) == {:ok, :is_user_present, false}
  end

  test "CenterDisplayState: integer passthrough" do
    assert FieldMapper.map("CenterDisplayState", 2) == {:ok, :center_display_state, 2}
  end

  # --- TPMS (pass through as float, no conversion) ---

  test "TpmsPressureFl: string to float" do
    assert FieldMapper.map("TpmsPressureFl", "2.9") == {:ok, :tpms_pressure_fl, 2.9}
  end

  test "TpmsPressureFr: string to float" do
    assert FieldMapper.map("TpmsPressureFr", "3.0") == {:ok, :tpms_pressure_fr, 3.0}
  end

  test "TpmsPressureRl: string to float" do
    assert FieldMapper.map("TpmsPressureRl", "3.1") == {:ok, :tpms_pressure_rl, 3.1}
  end

  test "TpmsPressureRr: string to float" do
    assert FieldMapper.map("TpmsPressureRr", "3.2") == {:ok, :tpms_pressure_rr, 3.2}
  end

  # --- GpsHeading ---

  test "GpsHeading: string to rounded integer" do
    assert FieldMapper.map("GpsHeading", "274.5") == {:ok, :heading, 275}
  end

  test "GpsHeading: integer passthrough" do
    assert FieldMapper.map("GpsHeading", 180) == {:ok, :heading, 180}
  end

  # --- Unknown fields ---

  test "unknown field returns :ignore" do
    assert FieldMapper.map("SomeUnknownField", "whatever") == :ignore
  end

  test "another unknown field returns :ignore" do
    assert FieldMapper.map("BogusFieldName", 42) == :ignore
  end

  # --- Invalid/malformed values ---

  test "VehicleSpeed: non-parseable string returns :invalid" do
    assert FieldMapper.map("VehicleSpeed", "not_a_number") == :invalid
  end

  test "Odometer: non-parseable string returns :invalid" do
    assert FieldMapper.map("Odometer", "abc") == :invalid
  end

  test "EstBatteryRange: boolean value returns :invalid" do
    assert FieldMapper.map("EstBatteryRange", true) == :invalid
  end

  test "InsideTemp: boolean value returns :invalid" do
    assert FieldMapper.map("InsideTemp", true) == :invalid
  end

  # --- ClimateKeeperMode ---

  test "ClimateKeeperMode: string passthrough" do
    assert FieldMapper.map("ClimateKeeperMode", "dog") == {:ok, :climate_keeper_mode, "dog"}
  end

  test "ClimateKeeperMode: off" do
    assert FieldMapper.map("ClimateKeeperMode", "off") == {:ok, :climate_keeper_mode, "off"}
  end
end
