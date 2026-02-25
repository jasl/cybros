require "ipaddr"

module Conduits
  # V1: domain:port allowlist（含 *.<domain> 通配）
  #
  # 重要语义（与 Go 端同构）：
  # - 域名大小写不敏感，统一 lower-case
  # - 规范化尾点：example.com. -> example.com
  # - '*.example.com' 匹配 a.example.com / b.a.example.com，但不匹配 example.com
  # - V1 禁止 IP 字面量（IPv4/IPv6），避免绕过审计
  module NetPolicyV1
    HOST_RE = /\A(localhost|(\*\.)?([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+)\z/i
    ENTRY_RE = /\A(?<host>[^:]+):(?<port>\d{1,5})\z/

    Entry = Struct.new(:raw, :host, :port, :wildcard, keyword_init: true) do
      def to_s
        "#{wildcard ? "*." : ""}#{host}:#{port}"
      end
    end

    class ParseError < StandardError; end

    module_function

    def normalize_host(host)
      h = host.to_s.strip
      h = h[0..-2] if h.end_with?(".")
      h.downcase
    end

    def ip_literal?(host)
      h = host.to_s
      return true if h.start_with?("[") && h.end_with?("]") # [::1]
      return true if h.include?(":") # naive IPv6 detection (V1 禁止)
      # IPv4
      !!(h =~ /\A\d{1,3}(?:\.\d{1,3}){3}\z/)
    end

    def parse_entry(str)
      s = str.to_s.strip
      m = ENTRY_RE.match(s)
      raise ParseError, "invalid entry format, expected host:port: #{s.inspect}" unless m

      host_raw = m[:host]
      port = Integer(m[:port], 10)
      raise ParseError, "port out of range: #{port}" unless (1..65_535).cover?(port)

      raise ParseError, "IP literal is not allowed in V1: #{host_raw.inspect}" if ip_literal?(host_raw)

      wildcard = false
      host = host_raw
      if host.start_with?("*.") # wildcard
        wildcard = true
        host = host[2..]
      end

      host = normalize_host(host)
      raise ParseError, "invalid host: #{host.inspect}" unless HOST_RE.match?(host)

      Entry.new(raw: s, host: host, port: port, wildcard: wildcard)
    rescue ArgumentError
      raise ParseError, "invalid port: #{m && m[:port].inspect}"
    end

    def parse_allowlist(list)
      Array(list).map { |e| parse_entry(e) }
    end

    def match?(entry, dest_host, dest_port)
      host = normalize_host(dest_host)
      port = Integer(dest_port, 10)
      return false unless port == entry.port

      if entry.wildcard
        # *.example.com matches foo.example.com but not example.com
        return false if host == entry.host
        host.end_with?(".#{entry.host}")
      else
        host == entry.host
      end
    rescue ArgumentError
      false
    end
  end
end
