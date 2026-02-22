defmodule TeslaMate.FleetTelemetry.ConsumerTest do
  use ExUnit.Case, async: true

  alias TeslaMate.FleetTelemetry.Consumer

  # --- Topic parsing ---

  describe "parse_topic/2" do
    test "extracts VIN and field from vehicle data topic" do
      assert Consumer.parse_topic("telemetry", "telemetry/5YJ3E1EA1NF123456/v/VehicleSpeed") ==
               {:ok, "5YJ3E1EA1NF123456", "VehicleSpeed"}
    end

    test "extracts VIN from connectivity topic" do
      assert Consumer.parse_topic("telemetry", "telemetry/5YJ3E1EA1NF123456/connectivity") ==
               {:ok, "5YJ3E1EA1NF123456", :connectivity}
    end

    test "handles nested field names" do
      assert Consumer.parse_topic("telemetry", "telemetry/5YJ3E1EA1NF123456/v/Location") ==
               {:ok, "5YJ3E1EA1NF123456", "Location"}
    end

    test "handles custom topic base" do
      assert Consumer.parse_topic("custom/base", "custom/base/VINABCDEF12345678/v/BatteryLevel") ==
               {:ok, "VINABCDEF12345678", "BatteryLevel"}
    end

    test "returns error for non-matching topic" do
      assert Consumer.parse_topic("telemetry", "other/topic/path") == :error
    end

    test "returns error for incomplete topic" do
      assert Consumer.parse_topic("telemetry", "telemetry/VIN123") == :error
    end
  end

  # --- Payload decoding ---

  describe "decode_payload/1" do
    test "decodes JSON string" do
      assert Consumer.decode_payload("\"34.797\"") == {:ok, "34.797"}
    end

    test "decodes JSON integer" do
      assert Consumer.decode_payload("42") == {:ok, 42}
    end

    test "decodes JSON float" do
      assert Consumer.decode_payload("3.14") == {:ok, 3.14}
    end

    test "decodes JSON boolean" do
      assert Consumer.decode_payload("true") == {:ok, true}
      assert Consumer.decode_payload("false") == {:ok, false}
    end

    test "decodes JSON object" do
      assert Consumer.decode_payload(~s({"latitude":30.0,"longitude":-97.0})) ==
               {:ok, %{"latitude" => 30.0, "longitude" => -97.0}}
    end

    test "decodes JSON object with booleans" do
      payload = ~s({"DriverFront":true,"PassengerFront":false})

      assert Consumer.decode_payload(payload) ==
               {:ok, %{"DriverFront" => true, "PassengerFront" => false}}
    end

    test "returns error for invalid JSON" do
      assert Consumer.decode_payload("not json at all") == :error
    end

    test "returns error for empty string" do
      assert Consumer.decode_payload("") == :error
    end
  end

  # --- Full message processing pipeline ---

  describe "process_message/3" do
    test "returns mapped field for valid vehicle data message" do
      result = Consumer.process_message("telemetry", "telemetry/VIN123/v/VehicleSpeed", "\"34.797\"")
      # Speed stays in mph (rounded) — create_position does the km/h conversion
      assert result == {:ok, "VIN123", :speed, 35}
    end

    test "returns mapped location for valid location message" do
      payload = ~s({"latitude":30.0,"longitude":-97.0})
      result = Consumer.process_message("telemetry", "telemetry/VIN123/v/Location", payload)
      assert result == {:ok, "VIN123", :location, %{latitude: 30.0, longitude: -97.0}}
    end

    test "returns connectivity event" do
      result = Consumer.process_message("telemetry", "telemetry/VIN123/connectivity", "\"online\"")
      assert result == {:connectivity, "VIN123", "online"}
    end

    test "returns :ignore for unknown field" do
      result = Consumer.process_message("telemetry", "telemetry/VIN123/v/UnknownField", "\"x\"")
      assert result == :ignore
    end

    test "returns :error for unparseable topic" do
      result = Consumer.process_message("telemetry", "wrong/topic", "\"x\"")
      assert result == :error
    end

    test "returns :error for invalid JSON payload" do
      result = Consumer.process_message("telemetry", "telemetry/VIN123/v/BatteryLevel", "bad")
      assert result == :error
    end

    test "returns :invalid for mismatched value type" do
      result = Consumer.process_message("telemetry", "telemetry/VIN123/v/EstBatteryRange", "true")
      assert result == :invalid
    end
  end
end
