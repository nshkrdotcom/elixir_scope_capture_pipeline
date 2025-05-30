defmodule ElixirScope.Capture.PipelineTest do
  use ExUnit.Case
  doctest ElixirScope.Capture.Pipeline

  test "greets the world" do
    assert ElixirScope.Capture.Pipeline.hello() == :world
  end
end
