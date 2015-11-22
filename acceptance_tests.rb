require 'minitest/autorun'
require 'set'
require 'socket'
require_relative 'pennmush_dbparser'
require_relative 'processors'

class AcceptanceTests < MiniTest::Unit::TestCase

  def sysdo(array)
    system(array.join(' && '))
  end

  def pennmush_outdb
    File.join(%w[test-pennmush game data outdb])
  end

  def pennmush_pidfile
    File.join(%w[test-pennmush game netmush.pid])
  end

  def pennmush_install
    sysdo([
      'git clone https://github.com/pennmush/pennmush.git test-pennmush',
      'cd test-pennmush',
      'git checkout 185p7',
      './configure  --without-mysql --without-postgresql --without-sqlite3 --disable-info_slave --disable-ssl_slave',
      'cp options.h.dist options.h',
      'make install',
      'make update',
      'sed -i"" "s/^compress_program.*/compress_program/" ./game/mush.cnf',
      'sed -i"" "s/^uncompress_program.*/uncompress_program/" ./game/mush.cnf',
      'sed -i"" "s/^compress_suffix.*/compress_suffix/" ./game/mush.cnf',
    ])
  end

  def pennmush_wait_for_dbfile
      debug "Waiting for database file to exist."
      loop until File.exist?(pennmush_outdb)
      debug "Waiting for end of dump."
      loop until File.readlines(pennmush_outdb).last.chomp == '***END OF DUMP***'
  end

  def pennmush_shutdown
    if File.exist?(pennmush_pidfile)
      debug "Shutting down running PennMUSH."
      pid = File.read(pennmush_pidfile).to_i
      Process.kill("INT", pid)
      pennmush_wait_for_dbfile
    end
    @pennsocket = nil
  end

  def pennmush_dump
    debug "Sending @dump"
    pennmush_send('@dump')
    pennmush_wait_for_dbfile
  end

  def pennmush_send(string)
    @pennsocket.puts(string)
  end

  def debug(msg)
    puts "--QBTester: #{msg}"
  end

  def pennmush_establish
    pennsocket = nil
    until pennsocket
      begin
        pennsocket = TCPSocket.new('localhost', 4201)
        return pennsocket
      rescue Errno::ECONNREFUSED
        retry
      end
    end
  end

  def pennmush_startup
    File.delete(pennmush_outdb) if File.exist?(pennmush_outdb)
    sysdo([
      'cd ' + File.join(%w[test-pennmush game]),
      './restart',
    ])
    debug "Establishing socket"
    @pennsocket = pennmush_establish
    debug "Socket established. Waiting for output."
    while line = @pennsocket.gets()
      break if /^----------/ =~ line
    end
    debug "Output received. Connecting character."
    @pennsocket.puts('connect #1')
    @pennsocket.puts('think -- BEGIN TEST SUITE --')
    while line = @pennsocket.gets()
      break if '-- BEGIN TEST SUITE --' == line.chomp
    end
    debug "Connected successfully."
  end

  def pennmush_dbread
    PennMUSHDBParser.parse_file(pennmush_outdb)
  end

  def pennmush_test(rooms, exits)
    debug "Testing grid equality"
    pennmush_dump
    db = pennmush_dbread
    assert_equal rooms, db[:rooms]
    assert_equal exits, db[:exits]
  end

  def setup
    pennmush_install unless Dir.exist?('test-pennmush')
    pennmush_startup
    pennmush_send("connect #1")
    @rooms = Set.new()
    @exits = Set.new()
  end

  def teardown
    pennmush_shutdown
  end

  def construct_and_send_grid(quickbuild_string)
    debug "Constructing Grid"
    quickbuild_string_array = quickbuild_string.split("\n").map(&:strip)
    commandlist = process_file(quickbuild_string_array, SYNTAXP)
    graph = process_opcodes(commandlist, {})
    softcode = process_graph(graph, {})
    pennmush_send(softcode.join("\n"))
  end

  def room(name, features = {})
    @rooms.add({:name => name}).merge(features)
  end

  def link(name, source, destination, features = {})
    @exits.add({:name => name, :source => source, :destination => destination}.merge(features))
  end

  def test_simple_grid
    room "Red Room"
    room "Blue Room"
    link "Higher", "Red Room", "Blue Room"
    link "Lower", "Blue Room", "Red Room"

    construct_and_send_grid(<<-EOS
      "Higher" : "Red Room"  -> "Blue Room"
      "Lower"  : "Blue Room" -> "Red Room"
EOS
    )

    pennmush_test(@rooms, @exits)
  end

  # TODO: Tests to write:
  # Basic Grid Creation
  # Parent/Zone application with room-ordering properties
  # Tag tests (Maze test)
  # Idempotency tests
  # Shop exits feature
  # Error tests:
  #  - Ensure "No entrance to Room X" appears
  #  - Ensure "No exits from Room X" appears
  #  - Prefix all errors with "QB:"
  #  - Add line numbers and room
  # Coalesce warnings to bottom of output
  # Include line number and code to jump to offending room in error messages

end
