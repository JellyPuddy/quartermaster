# frozen_string_literal: true

require "socket"
require "uri"
require "json"
require "base64"
require "digest"
require "securerandom"
require "fileutils"

# A small Chrome DevTools Protocol client: a client-side WebSocket (RFC 6455)
# over TCPSocket, the CDP request/response/event plumbing on top of it, and a
# headless Chrome launched with a throwaway profile. Stdlib only.
module ShowcaseShots
  class ProtocolError < StandardError; end

  # WebSocket frames. A client masks every frame it sends; Chrome's frames come unmasked.
  module Frame
    CONTINUATION = 0x0
    TEXT = 0x1
    BINARY = 0x2
    CLOSE = 0x8
    PING = 0x9
    PONG = 0xA

    module_function

    def encode(payload, opcode = TEXT, mask: SecureRandom.random_bytes(4), fin: true)
      data = payload.b
      len = data.bytesize
      head = [(fin ? 0x80 : 0) | opcode].pack("C")
      mask_bit = mask ? 0x80 : 0
      head << if len < 126 then [mask_bit | len].pack("C")
              elsif len < 65_536 then [mask_bit | 126, len].pack("Cn")
              else [mask_bit | 127, len].pack("CQ>")
              end
      return head + data unless mask

      head + mask.b + apply_mask(data, mask.b)
    end

    # Reads one frame from `io` (anything with read(n) returning exactly n
    # bytes) and returns [opcode, payload, fin].
    def decode(io)
      b0, b1 = io.read(2).unpack("CC")
      len = b1 & 0x7f
      len = case len
            when 126 then io.read(2).unpack1("n")
            when 127 then io.read(8).unpack1("Q>")
            else len
            end
      mask = io.read(4) if b1 & 0x80 != 0
      payload = len.zero? ? +"" : io.read(len)
      payload = apply_mask(payload, mask) if mask
      [b0 & 0x0f, payload, b0 & 0x80 != 0]
    end

    def apply_mask(data, mask)
      keys = mask.bytes
      out = data.bytes
      out.each_index { |i| out[i] ^= keys[i % 4] }
      out.pack("C*")
    end
  end

  # A blocking WebSocket client: connect, send text, receive whole messages
  # (continuations joined, pings answered), with a deadline on every read.
  class WebSocketClient
    GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    attr_accessor :deadline

    def initialize(url)
      uri = URI(url)
      @sock = TCPSocket.new(uri.host, uri.port).tap(&:binmode)
      @buf = +"".b
      @deadline = nil
      handshake(uri)
    end

    def send_text(text) = @sock.write(Frame.encode(text, Frame::TEXT))

    # The next whole text message, or nil once the server closes.
    def receive
      message = +"".b
      loop do
        opcode, payload, fin = Frame.decode(self)
        case opcode
        when Frame::PING then @sock.write(Frame.encode(payload, Frame::PONG))
        when Frame::CLOSE then return nil
        when Frame::TEXT, Frame::BINARY, Frame::CONTINUATION
          message << payload
          return message.force_encoding(Encoding::UTF_8) if fin
        end
      end
    end

    # Exactly n bytes, waiting no later than the deadline.
    def read(count)
      while @buf.bytesize < count
        chunk = @sock.read_nonblock(1 << 16, exception: false)
        raise ProtocolError, "Chrome closed the DevTools connection" if chunk.nil?

        if chunk == :wait_readable
          wait = @deadline ? @deadline - Time.now : nil
          raise ProtocolError, "timed out waiting for Chrome" if wait && (wait <= 0 || !@sock.wait_readable(wait))
        else
          @buf << chunk.b
        end
      end
      @buf.slice!(0, count)
    end

    def close
      @sock.write(Frame.encode([1000].pack("n"), Frame::CLOSE))
    rescue StandardError
      nil
    ensure
      @sock.close unless @sock.closed?
    end

    private

    def handshake(uri)
      key = Base64.strict_encode64(SecureRandom.random_bytes(16))
      @sock.write("GET #{uri.request_uri} HTTP/1.1\r\nHost: #{uri.host}:#{uri.port}\r\n" \
                  "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: #{key}\r\n" \
                  "Sec-WebSocket-Version: 13\r\n\r\n")
      head = +""
      head << @sock.readpartial(1) until head.end_with?("\r\n\r\n")
      expected = Base64.strict_encode64(Digest::SHA1.digest(key + GUID))
      raise ProtocolError, "websocket handshake refused: #{head.lines.first}" unless head.start_with?("HTTP/1.1 101") && head.include?(expected)
    end
  end

  # CDP over one browser-level WebSocket; page commands carry a sessionId
  # (Target.attachToTarget with flatten).
  class Cdp
    def initialize(ws_url)
      @ws = WebSocketClient.new(ws_url)
      @next_id = 0
      @events = []
    end

    def call(method, params = {}, session: nil, timeout: 30)
      id = (@next_id += 1)
      message = { id: id, method: method, params: params }
      message[:sessionId] = session if session
      @ws.send_text(JSON.generate(message))
      @ws.deadline = Time.now + timeout
      loop do
        reply = next_message
        if reply["id"] == id
          raise ProtocolError, "#{method}: #{reply['error']['message']}" if reply["error"]

          return reply["result"]
        end
        @events << reply if reply["method"]
      end
    end

    # Waits for an event (already received or still to come) and returns its params.
    def wait_event(method, session: nil, timeout: 30)
      @ws.deadline = Time.now + timeout
      loop do
        found = @events.index { |e| e["method"] == method && e["sessionId"] == session }
        return @events.delete_at(found)["params"] if found

        reply = next_message
        @events << reply if reply["method"]
      end
    end

    def drop_events(session) = @events.reject! { |e| e["sessionId"] == session }

    def close = @ws.close

    private

    def next_message
      text = @ws.receive or raise ProtocolError, "Chrome closed the DevTools connection"
      JSON.parse(text)
    end
  end

  # A headless Chrome with a throwaway profile under `profile_dir`, its
  # DevTools on a free port (Chrome picks it and writes DevToolsActivePort).
  class Chrome
    BINARY = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

    def initialize(profile_dir, binary: BINARY, log: File::NULL)
      @profile_dir = profile_dir
      @binary = binary
      @log = log
    end

    def start(timeout: 20)
      raise ProtocolError, "no Google Chrome at #{@binary}" unless File.executable?(@binary)

      FileUtils.rm_rf(@profile_dir)
      FileUtils.mkdir_p(@profile_dir)
      @pid = Process.spawn(@binary, "--headless=new", "--remote-debugging-port=0",
                           "--user-data-dir=#{@profile_dir}", "--no-first-run", "--no-default-browser-check",
                           "--hide-scrollbars", "--disable-extensions", "--disable-sync", "--mute-audio",
                           "--force-color-profile=srgb", "--disable-gpu", "--disable-renderer-backgrounding",
                           "--disable-background-timer-throttling", "--disable-backgrounding-occluded-windows",
                           "about:blank",
                           in: File::NULL, out: [@log, "a"], err: [@log, "a"], pgroup: true)
      Cdp.new(ws_url(timeout))
    end

    def stop
      return unless @pid

      begin
        Process.kill("TERM", -@pid)
        Process.wait(@pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
      @pid = nil
      FileUtils.rm_rf(@profile_dir)
    end

    private

    def ws_url(timeout)
      file = File.join(@profile_dir, "DevToolsActivePort")
      deadline = Time.now + timeout
      until File.size?(file) && File.read(file).lines.size >= 2
        raise ProtocolError, "Chrome did not open DevTools within #{timeout}s; see #{@log}" if Time.now > deadline

        sleep 0.1
      end
      port, path = File.read(file).lines.map(&:strip)
      "ws://127.0.0.1:#{port}#{path}"
    end
  end
end
