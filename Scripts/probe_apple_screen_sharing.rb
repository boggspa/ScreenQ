#!/usr/bin/env ruby
# frozen_string_literal: true

# Probes RFB security types for Apple Screen Sharing / Remote Management.
# It does not authenticate or send credentials. Use this before/after live
# Screen Q tests to verify whether a Mac offers Apple DH security type 30.

require "json"
require "socket"
require "timeout"

SECURITY_TYPES = {
  0 => "Invalid",
  1 => "None",
  2 => "VNCAuth",
  30 => "AppleDH"
}.freeze

def usage
  warn "Usage: Scripts/probe_apple_screen_sharing.rb [--require-apple-dh] host[:port] ..."
  exit 64
end

require_apple_dh = false
targets = []
ARGV.each do |arg|
  if arg == "--require-apple-dh"
    require_apple_dh = true
  elsif arg.start_with?("-")
    usage
  else
    targets << arg
  end
end
usage if targets.empty?

def parse_target(target)
  if target.start_with?("[")
    host, rest = target[1..].split("]", 2)
    port = rest&.sub(/^:/, "")
    return [host, Integer(port || "5900")]
  end

  host, maybe_port = target.split(":", 2)
  return [host, Integer(maybe_port)] if maybe_port&.match?(/\A\d+\z/)

  [target, 5900]
end

def read_exact(socket, count)
  data = +""
  while data.bytesize < count
    chunk = socket.read(count - data.bytesize)
    raise EOFError, "connection closed while reading #{count} bytes" if chunk.nil? || chunk.empty?

    data << chunk
  end
  data
end

def probe(target)
  host, port = parse_target(target)
  Timeout.timeout(5) do
    socket = TCPSocket.new(host, port)
    begin
      version = read_exact(socket, 12)
      unless version.start_with?("RFB ")
        return {
          target: target,
          host: host,
          port: port,
          ok: false,
          error: "Not an RFB endpoint: #{version.inspect}"
        }
      end

      socket.write("RFB 003.008\n")
      if version =~ /\ARFB\s+(\d+)\.(\d+)/
        minor = Regexp.last_match(2).to_i
      else
        minor = 8
      end

      types = []
      reason = nil
      if minor <= 3
        security_type = read_exact(socket, 4).unpack1("N")
        types = [security_type]
      else
        count = read_exact(socket, 1).unpack1("C")
        if count.zero?
          length = read_exact(socket, 4).unpack1("N")
          reason = read_exact(socket, length)
        else
          types = read_exact(socket, count).bytes
        end
      end

      {
        target: target,
        host: host,
        port: port,
        ok: true,
        protocol_version: version.strip,
        security_types: types.map { |type| { id: type, name: SECURITY_TYPES.fetch(type, "Unknown") } },
        apple_dh_offered: types.include?(30),
        vnc_password_offered: types.include?(2),
        reason: reason
      }
    ensure
      socket.close
    end
  end
rescue StandardError => e
  {
    target: target,
    ok: false,
    error: "#{e.class}: #{e.message}"
  }
end

results = targets.map { |target| probe(target) }
puts JSON.pretty_generate(results)

if require_apple_dh && results.any? { |result| !result[:ok] || !result[:apple_dh_offered] }
  exit 1
end
