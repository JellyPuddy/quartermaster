# frozen_string_literal: true

require "digest/sha1"
require "base64"

module Quartermaster
  # The server side of RFC 6455, just enough to carry a terminal: the
  # handshake answer, unmasked outgoing frames, masked incoming frames with
  # fragmentation, and ping/close handled in place. Stdlib only — the GUI's
  # chat pane is the one user.
  class WebSocket
    GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    TEXT = 1
    BINARY = 2
    CLOSE = 8
    PING = 9
    PONG = 10
    # A terminal never sends anything near this; a bigger length is garbage
    # or hostile, and reading it would allocate whatever it claims.
    MAX_PAYLOAD = 1 << 20

    class ProtocolError < StandardError; end

    def self.accept_key(key)
      Base64.strict_encode64(Digest::SHA1.digest("#{key}#{GUID}"))
    end

    def self.handshake_response(key)
      "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
        "Sec-WebSocket-Accept: #{accept_key(key)}\r\n\r\n"
    end

    # One frame as the server sends it: FIN set, never masked.
    def self.encode(payload, opcode)
      payload = payload.b
      len = payload.bytesize
      head = [0x80 | opcode].pack("C")
      head << if len < 126 then [len].pack("C")
              elsif len < 65_536 then [126, len].pack("Cn")
              else [127, len].pack("CQ>")
              end
      head + payload
    end

    def initialize(io)
      @io = io
      @write_lock = Mutex.new
    end

    def send_binary(data) = send_frame(data, BINARY)
    def send_text(data) = send_frame(data, TEXT)

    def send_frame(payload, opcode)
      frame = self.class.encode(payload, opcode)
      @write_lock.synchronize { @io.write(frame) }
    end

    def close(code = 1000)
      send_frame([code].pack("n"), CLOSE)
    rescue IOError, SystemCallError
      nil
    end

    # Yields [opcode, payload] per complete data message until the peer
    # closes or the connection drops. Control frames are answered here.
    def each_message
      message = nil
      opcode = nil
      loop do
        fin, op, data = read_frame
        break if op.nil?

        case op
        when CLOSE
          close
          break
        # Control frames may arrive between a message's fragments.
        when PING
          send_frame(data, PONG)
          next
        when PONG then next
        when 0
          raise ProtocolError, "continuation without a message" unless message

          message << data
          raise ProtocolError, "message too large" if message.bytesize > MAX_PAYLOAD
        else
          message = data
          opcode = op
        end
        next unless fin && message

        yield opcode, message
        message = nil
      end
    end

    private

    # nil op at end of stream. Clients must mask (RFC 6455 5.1).
    def read_frame
      head = @io.read(2)
      return [nil, nil, nil] unless head&.bytesize == 2

      b0, b1 = head.unpack("CC")
      len = b1 & 0x7f
      len = read_exact(2).unpack1("n") if len == 126
      len = read_exact(8).unpack1("Q>") if len == 127
      raise ProtocolError, "frame too large (#{len} bytes)" if len > MAX_PAYLOAD
      raise ProtocolError, "unmasked client frame" if (b1 & 0x80).zero?

      mask = read_exact(4).bytes
      data = len.zero? ? +"".b : read_exact(len)
      [b0 & 0x80 != 0, b0 & 0x0f, unmask(data, mask)]
    end

    def read_exact(count)
      data = @io.read(count)
      raise EOFError, "connection closed mid-frame" unless data&.bytesize == count

      data
    end

    def unmask(data, mask)
      bytes = data.bytes
      bytes.each_index { |i| bytes[i] ^= mask[i % 4] }
      bytes.pack("C*")
    end
  end
end
