defmodule HelloKioskBrain.CameraMonitorTest do
  use ExUnit.Case, async: true

  alias HelloKioskBrain.CameraMonitor

  test "decodes camera_viewer success ACK" do
    ack = <<0, 1920::16, 1080::16, 480::16, 270::16, 86_250::32, 7_125::32>>

    assert {:ok, metrics} = CameraMonitor.decode_ack(ack)
    assert metrics.input_width == 1920
    assert metrics.input_height == 1080
    assert metrics.output_width == 480
    assert metrics.output_height == 270
    assert metrics.decode_ms == 86.25
    assert metrics.framebuffer_ms == 7.125
  end

  test "decodes camera_viewer error ACK" do
    assert {:error, {:renderer, 2, "bad jpeg"}} =
             CameraMonitor.decode_ack(<<1, 2::16, "bad jpeg">>)
  end

  test "rejects malformed camera_viewer ACK" do
    assert {:error, {:invalid_renderer_ack, 2}} = CameraMonitor.decode_ack(<<0, 1>>)
  end

  test "accepts only configured HTTP snapshot URLs" do
    assert :ok = CameraMonitor.validate_snapshot_url("http://camera.local/snapshot.jpg")

    assert {:error, :https_not_supported} =
             CameraMonitor.validate_snapshot_url("https://camera.local/snapshot.jpg")

    assert {:error, :invalid_camera_url} = CameraMonitor.validate_snapshot_url("")
    assert {:error, :invalid_camera_url} = CameraMonitor.validate_snapshot_url("camera.local")
  end

  test "does not start the renderer without a configured camera" do
    {:ok, state} = CameraMonitor.init([])

    assert {:reply, {:error, :camera_not_configured}, ^state} =
             CameraMonitor.handle_call(:enable, self(), state)
  end
end
