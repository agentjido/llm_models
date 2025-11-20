#!/usr/bin/env elixir

Mix.install([
  {:req, "~> 0.5"},
  {:jason, "~> 1.4"}
])

defmodule Retirer do
  def run do
    package = "llm_db"
    # 90 days ~ 3 months
    retire_age_days = 90
    
    IO.puts("Fetching package info for #{package}...")
    
    # Get package info from Hex API
    case Req.get("https://hex.pm/api/packages/#{package}") do
      {:ok, %{status: 200, body: body}} ->
        process_releases(package, body["releases"], retire_age_days)
      
      {:ok, %{status: status}} ->
        IO.puts("Error fetching package: HTTP #{status}")
        System.halt(1)
        
      {:error, reason} ->
        IO.puts("Error fetching package: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp process_releases(package, releases, age_days) do
    now = DateTime.utc_now()
    
    releases
    |> Enum.filter(fn r -> !r["is_retired"] end)
    |> Enum.each(fn release ->
      version = release["version"]
      inserted_at = parse_date(release["inserted_at"])
      
      age = DateTime.diff(now, inserted_at, :day)
      
      if age > age_days do
        retire(package, version, age)
      else
        IO.puts("Skipping #{version} (Age: #{age} days)")
      end
    end)
  end

  defp parse_date(iso_string) do
    {:ok, date, _} = DateTime.from_iso8601(iso_string)
    date
  end

  defp retire(package, version, age) do
    IO.puts("Retiring #{package} #{version} (Age: #{age} days)...")
    
    # We use System.cmd to run the mix task
    # Note: This requires HEX_API_KEY to be set in the environment
    case System.cmd("mix", [
           "hex.retire",
           package,
           version,
           "deprecated",
           "--message",
           "This version is outdated. Please upgrade to the latest daily release.",
           "--yes"
         ], stderr_to_stdout: true) do
      {output, 0} ->
        IO.puts("Successfully retired #{version}")
        IO.puts(output)
        
      {output, code} ->
        IO.puts("Failed to retire #{version} (Exit code: #{code})")
        IO.puts(output)
        # We don't halt here, we try the next one
    end
  end
end

Retirer.run()
