# frozen_string_literal: true

module Quartermaster
  # A chat pane: the browser's /ws/terminal WebSocket bridged to a PTY
  # running a fresh `tmux attach` for this connection. Binary frames are
  # keystrokes, text frames are {cols, rows} resizes. Closing the socket (tab
  # closed or reloaded, GUI stopped) only kills that client — the chat lives
  # on in tmux and the next connection redraws it. The chat ending ends the
  # session, which exits the client and closes the socket.
  #
  # tmux sizes a chat's window to the client that attached, resized or typed
  # last (`window-size latest`). Every size frame therefore also signals
  # SIGWINCH to this client: the kernel sends none when the winsize did not
  # change, and only the signal makes tmux take this client's size again.
  class TerminalBridge
    COLS = 1..500
    ROWS = 1..200

    def initialize(tmux:, token:, guard:)
      @tmux = tmux
      @token = token
      @guard = guard
    end

    # Why a terminal WebSocket upgrade is refused, or nil to accept it. A
    # browser lets any website open a WebSocket to 127.0.0.1 and sends our
    # Host for it, so on top of the Host check the Origin must be our own
    # (present — unlike a POST, a browser always sends it here) and the
    # request must carry the token this server embedded in its page. Without
    # both, any page the user visits could type into a chat.
    def refusal(path, headers)
      route, query = path.to_s.split("?", 2)
      params = URI.decode_www_form(query.to_s).to_h
      return "not found" unless route == "/ws/terminal"
      return "bad host" unless @guard.allowed_host?(headers["host"])
      return "bad origin" unless headers["origin"] && !@guard.foreign_origin?(headers["origin"])
      return "bad token" unless token_matches?(params["token"])
      return "no such chat" unless @tmux.live?(params["session"])
      return "missing websocket key" unless headers["sec-websocket-key"]

      nil
    end

    def serve(client, path, headers)
      if (refusal = refusal(path, headers))
        client.write("HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain; charset=utf-8\r\n" \
                     "Content-Length: #{refusal.bytesize}\r\nConnection: close\r\n\r\n#{refusal}")
        return
      end

      params = URI.decode_www_form(path.split("?", 2)[1].to_s).to_h
      client.write(WebSocket.handshake_response(headers["sec-websocket-key"]))
      bridge(WebSocket.new(client), params["session"],
             cols: params["cols"].to_i.clamp(COLS), rows: params["rows"].to_i.clamp(ROWS))
    end

    private

    def token_matches?(token)
      return false unless token.is_a?(String) && token.bytesize == @token.bytesize

      token.bytes.zip(@token.bytes).sum { |a, b| a ^ b }.zero?
    end

    def bridge(socket, name, cols:, rows:)
      reader, writer, pid = PTY.spawn({ "TERM" => "xterm-256color", "TMUX" => nil }, *@tmux.attach_command(name))
      reader.winsize = [rows, cols]
      pump = Thread.new do
        loop { socket.send_binary(reader.readpartial(16_384)) }
      rescue EOFError, IOError, SystemCallError
        socket.close
      end
      socket.each_message do |opcode, data|
        if opcode == WebSocket::TEXT
          size = JSON.parse(data)
          resize(pid, reader, size["cols"], size["rows"]) if size["cols"]
        else
          writer.write(data)
        end
      end
    rescue WebSocket::ProtocolError, IOError, SystemCallError, JSON::ParserError => e
      Quartermaster.log_error("gui-terminal", e) unless e.is_a?(IOError) || e.is_a?(Errno::EPIPE)
    ensure
      stop_client(pid, pump, reader, writer)
    end

    def resize(pid, pty, cols, rows)
      pty.winsize = [rows.to_i.clamp(ROWS), cols.to_i.clamp(COLS)]
      Process.kill("WINCH", pid)
    rescue Errno::ESRCH
      nil
    end

    def stop_client(pid, pump, *ios)
      if pid
        begin
          Process.kill("TERM", pid)
        rescue SystemCallError
          nil
        end
        Process.detach(pid)
      end
      pump&.kill
      ios.compact.each { |io| io.close unless io.closed? }
    end
  end
end
