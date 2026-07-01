defmodule CaudataTest do
  use ExUnit.Case
  doctest Caudata

  test "greets the world" do
    assert Caudata.hello() == :world
  end

  test "tailscale service get_status/0 returns current status" do
    status = Caudata.Tailscale.Service.get_status()
    # In test environment, tailscale is either inactive, connecting, or in an error state
    assert status == :inactive or status == :connecting or match?({:error, _}, status)
  end
end
