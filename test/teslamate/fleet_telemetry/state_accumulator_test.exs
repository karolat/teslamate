defmodule TeslaMate.FleetTelemetry.StateAccumulatorTest do
  use ExUnit.Case, async: true

  alias TeslaMate.FleetTelemetry.StateAccumulator
  alias TeslaApi.Vehicle
  alias TeslaApi.Vehicle.State.{Drive, Charge, Climate, VehicleState, VehicleConfig}

  # --- Basic accumulation ---

  test "new/0 creates an empty accumulator" do
    acc = StateAccumulator.new()
    assert StateAccumulator.get(acc, :speed) == nil
  end

  test "put/3 and get/2 store and retrieve values" do
    acc =
      StateAccumulator.new()
      |> StateAccumulator.put(:speed, 35)
      |> StateAccumulator.put(:battery_level, 75)

    assert StateAccumulator.get(acc, :speed) == 35
    assert StateAccumulator.get(acc, :battery_level) == 75
  end

  test "later puts overwrite earlier values" do
    acc =
      StateAccumulator.new()
      |> StateAccumulator.put(:speed, 35)
      |> StateAccumulator.put(:speed, 72)

    assert StateAccumulator.get(acc, :speed) == 72
  end

  test "get returns nil for unset fields" do
    acc = StateAccumulator.new()
    assert StateAccumulator.get(acc, :nonexistent) == nil
  end

  # --- Power computation ---

  test "computed_power returns kW from voltage and current" do
    acc =
      StateAccumulator.new()
      |> StateAccumulator.put(:pack_voltage, 395.0)
      |> StateAccumulator.put(:pack_current, -25.3)

    # 395.0 * -25.3 / 1000 = -9.9965 -> -10
    assert StateAccumulator.computed_power(acc) == -10
  end

  test "computed_power returns nil when only voltage is set" do
    acc =
      StateAccumulator.new()
      |> StateAccumulator.put(:pack_voltage, 395.0)

    assert StateAccumulator.computed_power(acc) == nil
  end

  test "computed_power returns nil when only current is set" do
    acc =
      StateAccumulator.new()
      |> StateAccumulator.put(:pack_current, -25.3)

    assert StateAccumulator.computed_power(acc) == nil
  end

  test "computed_power returns nil for empty accumulator" do
    assert StateAccumulator.computed_power(StateAccumulator.new()) == nil
  end

  test "computed_power with positive current (regen)" do
    acc =
      StateAccumulator.new()
      |> StateAccumulator.put(:pack_voltage, 400.0)
      |> StateAccumulator.put(:pack_current, 50.0)

    # 400.0 * 50.0 / 1000 = 20
    assert StateAccumulator.computed_power(acc) == 20
  end

  # --- Timestamp ---

  test "put_timestamp stores the timestamp" do
    now = DateTime.utc_now() |> DateTime.to_unix(:millisecond)
    acc = StateAccumulator.new() |> StateAccumulator.put_timestamp(now)
    assert StateAccumulator.get_timestamp(acc) == now
  end

  # --- to_vehicle ---

  test "to_vehicle builds a Vehicle struct with drive state (mph speed)" do
    now = DateTime.utc_now() |> DateTime.to_unix(:millisecond)

    acc =
      StateAccumulator.new()
      |> StateAccumulator.put_timestamp(now)
      |> StateAccumulator.put(:speed, 35)
      |> StateAccumulator.put(:location, %{latitude: 30.0, longitude: -97.0})
      |> StateAccumulator.put(:shift_state, "D")
      |> StateAccumulator.put(:heading, 275)

    vehicle = StateAccumulator.to_vehicle(acc, "online")

    assert %Vehicle{} = vehicle
    assert vehicle.state == "online"
    assert %Drive{} = vehicle.drive_state
    # Speed stays in mph — create_position does the km/h conversion
    assert vehicle.drive_state.speed == 35
    assert vehicle.drive_state.latitude == 30.0
    assert vehicle.drive_state.longitude == -97.0
    assert vehicle.drive_state.shift_state == "D"
    assert vehicle.drive_state.heading == 275
    assert vehicle.drive_state.timestamp == now
  end

  test "to_vehicle builds a Vehicle struct with charge state (miles range)" do
    now = DateTime.utc_now() |> DateTime.to_unix(:millisecond)

    acc =
      StateAccumulator.new()
      |> StateAccumulator.put_timestamp(now)
      |> StateAccumulator.put(:battery_level, 75)
      |> StateAccumulator.put(:charging_state, "Charging")
      |> StateAccumulator.put(:charger_power, 48)
      |> StateAccumulator.put(:charger_voltage, 400)
      |> StateAccumulator.put(:charger_actual_current, 120)
      |> StateAccumulator.put(:charge_energy_added, 25.3)
      |> StateAccumulator.put(:charge_limit_soc, 80)
      |> StateAccumulator.put(:time_to_full_charge, 1.25)
      |> StateAccumulator.put(:fast_charger_present, true)
      # Range values are in miles — create_position converts to km
      |> StateAccumulator.put(:est_battery_range, 131.5)
      |> StateAccumulator.put(:ideal_battery_range, 150.0)
      |> StateAccumulator.put(:battery_range, 200.5)

    vehicle = StateAccumulator.to_vehicle(acc, "online")

    assert %Charge{} = vehicle.charge_state
    assert vehicle.charge_state.battery_level == 75
    assert vehicle.charge_state.charging_state == "Charging"
    assert vehicle.charge_state.charger_power == 48
    assert vehicle.charge_state.charger_voltage == 400
    assert vehicle.charge_state.charger_actual_current == 120
    assert vehicle.charge_state.charge_energy_added == 25.3
    assert vehicle.charge_state.charge_limit_soc == 80
    assert vehicle.charge_state.time_to_full_charge == 1.25
    assert vehicle.charge_state.fast_charger_present == true
    assert vehicle.charge_state.est_battery_range == 131.5
    assert vehicle.charge_state.ideal_battery_range == 150.0
    assert vehicle.charge_state.battery_range == 200.5
    assert vehicle.charge_state.timestamp == now
  end

  test "to_vehicle builds a Vehicle struct with climate state" do
    now = DateTime.utc_now() |> DateTime.to_unix(:millisecond)

    acc =
      StateAccumulator.new()
      |> StateAccumulator.put_timestamp(now)
      |> StateAccumulator.put(:inside_temp, 22.5)
      |> StateAccumulator.put(:outside_temp, -5.2)
      |> StateAccumulator.put(:climate_keeper_mode, "dog")

    vehicle = StateAccumulator.to_vehicle(acc, "online")

    assert %Climate{} = vehicle.climate_state
    assert vehicle.climate_state.inside_temp == 22.5
    assert vehicle.climate_state.outside_temp == -5.2
    assert vehicle.climate_state.climate_keeper_mode == "dog"
    assert vehicle.climate_state.timestamp == now
  end

  test "to_vehicle builds a Vehicle struct with vehicle state" do
    now = DateTime.utc_now() |> DateTime.to_unix(:millisecond)

    acc =
      StateAccumulator.new()
      |> StateAccumulator.put_timestamp(now)
      |> StateAccumulator.put(:car_version, "2024.8.9 abc123")
      |> StateAccumulator.put(:locked, true)
      |> StateAccumulator.put(:sentry_mode, true)
      |> StateAccumulator.put(:is_user_present, false)
      |> StateAccumulator.put(:center_display_state, 2)
      |> StateAccumulator.put(:display_name, "My Tesla")
      # Odometer stays in miles — create_position converts to km
      |> StateAccumulator.put(:odometer, 11270.94)
      |> StateAccumulator.put(:tpms_pressure_fl, 2.9)
      |> StateAccumulator.put(:tpms_pressure_fr, 3.0)
      |> StateAccumulator.put(:tpms_pressure_rl, 3.1)
      |> StateAccumulator.put(:tpms_pressure_rr, 3.2)

    vehicle = StateAccumulator.to_vehicle(acc, "online")

    assert %VehicleState{} = vehicle.vehicle_state
    assert vehicle.vehicle_state.car_version == "2024.8.9 abc123"
    assert vehicle.vehicle_state.locked == true
    assert vehicle.vehicle_state.sentry_mode == true
    assert vehicle.vehicle_state.is_user_present == false
    assert vehicle.vehicle_state.center_display_state == 2
    assert vehicle.vehicle_state.odometer == 11270.94
    assert vehicle.vehicle_state.tpms_pressure_fl == 2.9
    assert vehicle.vehicle_state.tpms_pressure_fr == 3.0
    assert vehicle.vehicle_state.tpms_pressure_rl == 3.1
    assert vehicle.vehicle_state.tpms_pressure_rr == 3.2
    assert vehicle.vehicle_state.timestamp == now

    assert vehicle.display_name == "My Tesla"
  end

  test "to_vehicle converts door booleans to legacy integer format" do
    acc =
      StateAccumulator.new()
      |> StateAccumulator.put(:doors, %{
        df: true,
        pf: false,
        dr: false,
        pr: false,
        ft: false,
        rt: true
      })

    vehicle = StateAccumulator.to_vehicle(acc, "online")

    assert vehicle.vehicle_state.df == 1
    assert vehicle.vehicle_state.pf == 0
    assert vehicle.vehicle_state.dr == 0
    assert vehicle.vehicle_state.pr == 0
    assert vehicle.vehicle_state.ft == 0
    assert vehicle.vehicle_state.rt == 1
  end

  test "to_vehicle converts window atoms to legacy integer format" do
    acc =
      StateAccumulator.new()
      |> StateAccumulator.put(:fd_window, :open)
      |> StateAccumulator.put(:fp_window, :closed)
      |> StateAccumulator.put(:rd_window, :closed)
      |> StateAccumulator.put(:rp_window, :open)

    vehicle = StateAccumulator.to_vehicle(acc, "online")

    assert vehicle.vehicle_state.fd_window == 1
    assert vehicle.vehicle_state.fp_window == 0
    assert vehicle.vehicle_state.rd_window == 0
    assert vehicle.vehicle_state.rp_window == 1
  end

  test "to_vehicle computes power from pack_voltage and pack_current" do
    acc =
      StateAccumulator.new()
      |> StateAccumulator.put(:pack_voltage, 395.0)
      |> StateAccumulator.put(:pack_current, 25.3)

    vehicle = StateAccumulator.to_vehicle(acc, "online")

    # 395.0 * 25.3 / 1000 = 9.9965 -> 10
    assert vehicle.drive_state.power == 10
  end

  test "to_vehicle power is nil when pack data incomplete" do
    acc =
      StateAccumulator.new()
      |> StateAccumulator.put(:pack_voltage, 395.0)

    vehicle = StateAccumulator.to_vehicle(acc, "online")
    assert vehicle.drive_state.power == nil
  end

  test "to_vehicle includes a stub VehicleConfig" do
    vehicle = StateAccumulator.to_vehicle(StateAccumulator.new(), "online")
    assert %VehicleConfig{} = vehicle.vehicle_config
  end

  test "to_vehicle with range fields in miles" do
    acc =
      StateAccumulator.new()
      |> StateAccumulator.put(:est_battery_range, 131.5)
      |> StateAccumulator.put(:ideal_battery_range, 150.0)
      |> StateAccumulator.put(:battery_range, 200.5)

    vehicle = StateAccumulator.to_vehicle(acc, "online")

    # Ranges are in miles, matching legacy API format
    assert vehicle.charge_state.est_battery_range == 131.5
    assert vehicle.charge_state.ideal_battery_range == 150.0
    assert vehicle.charge_state.battery_range == 200.5
  end

  # --- Multiple updates accumulate correctly ---

  test "sequential updates build complete state" do
    now = DateTime.utc_now() |> DateTime.to_unix(:millisecond)

    acc =
      StateAccumulator.new()
      |> StateAccumulator.put_timestamp(now)
      |> StateAccumulator.put(:speed, 65)
      |> StateAccumulator.put(:battery_level, 80)
      |> StateAccumulator.put(:location, %{latitude: 40.0, longitude: -74.0})
      |> StateAccumulator.put(:shift_state, "D")
      |> StateAccumulator.put(:charging_state, "Disconnected")
      |> StateAccumulator.put(:inside_temp, 21.0)
      |> StateAccumulator.put(:outside_temp, 15.0)
      |> StateAccumulator.put(:locked, true)
      |> StateAccumulator.put(:car_version, "2024.10.1 xyz")
      |> StateAccumulator.put(:display_name, "Road Tripper")

    vehicle = StateAccumulator.to_vehicle(acc, "online")

    assert vehicle.state == "online"
    assert vehicle.display_name == "Road Tripper"
    assert vehicle.drive_state.speed == 65
    assert vehicle.drive_state.latitude == 40.0
    assert vehicle.drive_state.shift_state == "D"
    assert vehicle.charge_state.battery_level == 80
    assert vehicle.charge_state.charging_state == "Disconnected"
    assert vehicle.climate_state.inside_temp == 21.0
    assert vehicle.vehicle_state.locked == true
    assert vehicle.vehicle_state.car_version == "2024.10.1 xyz"
  end
end
