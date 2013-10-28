require './test_common'
require 'timeout'

class TickleCount
  include Bud

  state do
    loopback :loop_chan, [:cnt]
    channel :mcast, [:@addr, :cnt]
    scratch :loopback_done, [:nums]
    scratch :mcast_done, [:nums]
  end

  bootstrap do
    loop_chan <~ [[0]]
  end

  bloom :count_to_5 do
    loop_chan <~ loop_chan {|l| [l.cnt + 1] if l.cnt < 6}
    loopback_done <= loop_chan {|l| [l.cnt] if l.cnt == 5}

    mcast <~ loop_chan {|l| [ip_port, l.cnt] if l.cnt < 6}
    mcast_done <= mcast {|m| [m.cnt] if m.cnt == 5}
  end
end

class TestTickle < MiniTest::Unit::TestCase
  def test_tickle_run_bg
    c = TickleCount.new
    assert_equal([:cnt], c.mcast.payload_schema)
    assert_equal([:cnt], c.loop_chan.payload_schema)

    # Check that the program is stratified as we'd expect
    assert_equal(2, c.stratified_rules.length)
    deps = c.t_depends.select {|d| d.lhs == "mcast" and d.body == "loop_chan"}
    assert_equal(1, deps.size)
    assert_equal(false, deps.first.nm)

    q = Queue.new
    c.register_callback(:loopback_done) do |t|
      assert_equal([[5]], t.to_a)
      q.push(true)
    end
    c.register_callback(:mcast_done) do |t|
      assert_equal([[5]], t.to_a)
      q.push(true)
    end

    c.run_bg
    q.pop ; q.pop
    c.stop
  end

  def test_tickle_single_step
    c = TickleCount.new
    q = Queue.new
    c.register_callback(:loopback_done) do |t|
      q.push(t.to_a.first)
    end
    c.register_callback(:mcast_done) do |t|
      q.push(t.to_a.first)
    end
    5.times do
      c.tick
      sleep 0.1
    end
    assert(q.empty?)
    10.times do
      c.tick
      break if q.length >= 2
      sleep 0.1
    end
    res1 = q.pop
    res2 = q.pop
    assert_equal([5], res1)
    assert_equal([5], res2)
    assert(q.empty?)
    c.stop
  end
end

class RingMember
  include Bud

  state do
    channel :pipe, [:@addr, :cnt]
    scratch :kickoff, [:cnt]
    table :next_guy, [:addr]
    table :last_cnt, [:cnt]
    scratch :done, [:cnt]
  end

  bloom :ring_msg do
    pipe <~ kickoff {|k| [ip_port, k.cnt]}
    pipe <~ (pipe * next_guy).pairs {|p,n| [n.addr, p.cnt + 1] if p.cnt < 39}
    done <= pipe {|p| [p.cnt] if p.cnt == 39}
  end

  bloom :update_log do
    last_cnt <+ pipe {|p| [p.cnt]}
    last_cnt <- (pipe * last_cnt).pairs {|p, lc| [lc.cnt]}
  end
end

class TestRing < MiniTest::Unit::TestCase
  RING_SIZE = 10

  def test_basic_ring
    ring = []
    RING_SIZE.times do |i|
      ring[i] = RingMember.new
      ring[i].run_bg
    end
    q = Queue.new
    ring.last.register_callback(:done) do
      q.push(true)
    end

    ring.each_with_index do |r, i|
      next_idx = i + 1
      next_idx = 0 if next_idx == RING_SIZE
      next_addr = ring[next_idx].ip_port

      r.sync_do {
        r.next_guy <+ [[next_addr]]
      }
    end

    first = ring.first
    first.async_do {
      first.kickoff <+ [[0]]
    }

    # Wait for the "done" callback from the last member of the ring.
    q.pop

    ring.each_with_index do |r, i|
      # XXX: we need to do a final tick here to ensure that each Bud instance
      # applies pending <+ and <- derivations. See issue #50.
      r.sync_do
      r.stop
      assert_equal([30 + i], r.last_cnt.first)
    end
  end
end

class ChannelWithKey
  include Bud

  state do
    channel :c, [:@addr, :k1] => [:v1]
    scratch :kickoff, [:addr, :v1, :v2]
    table :recv, c.key_cols => c.val_cols
    table :ploads
    table :ploads_blk
    table :ploads_blk_colnos
  end

  bloom do
    c <~ kickoff {|k| [k.addr, k.v1, k.v2]}
    recv <= c
    ploads <= c.payloads
    ploads_blk <= c.payloads {|m| [m.k1 + 1, m.v1 + 1]}
    ploads_blk_colnos <= c.payloads {|m| [m[0] + 2, m[1] + 2]}
  end
end

class PayloadForDefaultChannel
  include Bud

  state do
    channel :chn
    scratch :to_send, [:addr, :v]
    table :chn_payloads, [:v]
  end

  bloom do
    chn <~ to_send
    chn_payloads <= chn.payloads
  end
end

class TestPayloads < MiniTest::Unit::TestCase
  def test_channel_with_key
    p1 = ChannelWithKey.new
    p2 = ChannelWithKey.new

    q = Queue.new
    p2.register_callback(:recv) do
      q.push(true)
    end

    p1.run_bg
    p2.run_bg

    target_addr = p2.ip_port
    p1.sync_do {
      p1.kickoff <+ [[target_addr, 10, 20]]
      # Test that directly inserting into a channel also works
      p1.c <~ [[target_addr, 50, 100]]
    }

    # Wait for p2 to receive message
    q.pop

    p2.sync_do {
      assert_equal([[target_addr, 10, 20], [target_addr, 50, 100]], p2.recv.to_a.sort)
      assert_equal([[10, 20], [50, 100]], p2.ploads.to_a.sort)
      assert_equal([[11, 21], [51, 101]], p2.ploads_blk.to_a.sort)
      assert_equal([[12, 22], [52, 102]], p2.ploads_blk_colnos.to_a.sort)
    }

    # Check that inserting into a channel via <= is rejected
    assert_raises(Bud::CompileError) {
      p1.sync_do {
        p1.c <= [[target_addr, 60, 110]]
      }
    }

    # Check that key constraints on channels are raised
    assert_raises(Bud::KeyConstraintError) {
      p1.sync_do {
        p1.c <~ [[target_addr, 70, 120]]
        p1.c <~ [[target_addr, 70, 130]]
      }
    }

    p1.stop
    p2.stop
  end

  def test_default_payloads
    c = PayloadForDefaultChannel.new
    c.run_bg

    c.sync_callback(:to_send, [[c.ip_port, 5]], :chn)
    c.sync_do {
      assert_equal([[5]], c.chn_payloads.to_a)
    }

    c.stop
  end
end

class ChannelAddrInVal
  include Bud

  state do
    channel :c, [:k1] => [:@addr, :v1]
    scratch :kickoff, [:v1, :addr, :v2]
    table :recv, c.key_cols => c.val_cols
  end

  bloom do
    c <~ kickoff {|k| [k.v1, k.addr, k.v2]}
    recv <= c
  end
end

class TestChannelAddrInVal < MiniTest::Unit::TestCase
  def test_addr_in_val
    p1 = ChannelAddrInVal.new
    p2 = ChannelAddrInVal.new

    q = Queue.new
    p2.register_callback(:recv) do
      q.push(true)
    end

    p1.run_bg
    p2.run_bg

    target_addr = p2.ip_port
    p1.sync_do {
      p1.kickoff <+ [[10, target_addr, 20]]
      # Test that directly inserting into a channel also works
      p1.c <~ [[50, target_addr, 100]]
    }

    # Wait for p2 to receive message
    q.pop

    p2.sync_do {
      assert_equal([[10, target_addr, 20], [50, target_addr, 100]], p2.recv.to_a.sort)
    }

    p1.stop
    p2.stop
  end
end

class ChannelBootstrap
  include Bud

  state do
    loopback :loop_chan, [:foo]
    table :t1
    table :t2, [:foo]
  end

  bootstrap do
    loop_chan <~ [[1000]]
    t1 <= [[@ip, @port]]
  end

  bloom do
    t2 <= loop_chan
  end
end

class TestChannelBootstrap < MiniTest::Unit::TestCase
  def test_bootstrap
    c = ChannelBootstrap.new
    q = Queue.new
    c.register_callback(:loop_chan) do
      q.push(true)
    end
    c.run_bg

    c.sync_do {
      t = c.t1.to_a
      assert_equal(1, t.length)
      v = t.first
      assert(v[1] > 1024)
      assert_equal(v[0], c.ip)
    }
    q.pop
    c.sync_do {
      assert_equal([[1000]], c.t2.to_a.sort)
    }
    c.stop
  end
end

class ChannelWithoutLocSpec
  include Bud

  state do
    channel :c, [:foo, :bar]
  end
end

class ChannelWithMultiLocSpecs
  include Bud

  state do
    channel :c, [:@foo] => [:bar, :@baz]
  end
end

class LocSpecTests < MiniTest::Unit::TestCase
  def test_missing_ls
    assert_raises(Bud::Error) { ChannelWithoutLocSpec.new }
  end

  def test_dup_ls
    assert_raises(Bud::Error) { ChannelWithMultiLocSpecs.new }
  end
end

class LoopbackPayload
  include Bud

  state do
    loopback :me
    scratch :me_copy, me.schema
  end

  bootstrap do
    me <~ [["hello", "world"]]
  end

  bloom do
    me_copy <= me.payloads
  end
end

class SimpleLoopback
  include Bud

  state do
    loopback :me
    scratch :done
  end

  bootstrap do
    me <~ [["foo", 1]]
  end

  bloom do
    me <~ me {|t| [t.key, t.val + 1] if t.val <= 60}
    done <= me {|t| t if t.val > 60}
  end
end

class LoopbackTests < MiniTest::Unit::TestCase
  def test_loopback_payload
    b = LoopbackPayload.new
    q = Queue.new
    b.register_callback(:me_copy) do |t|
      assert_equal([["hello", "world"]], t.to_a.sort)
      q.push(true)
    end
    b.run_bg
    q.pop
    b.stop
  end

  def loop_for_msg(s, cnt)
    20.times do |i|
      sleep 0.1
      s.tick
      unless s.me.to_a.empty?
        assert_equal([["foo", cnt]], s.me.to_a)
        return
      end
    end
    flunk "Timeout (> 2 seconds) on loopback interface!"
  end

  def test_loopback_tick
    s = SimpleLoopback.new
    done_q = Queue.new
    s.register_callback(:done) do |t|
      done_q.push(t.to_a)
    end
    s.tick
    assert(s.me.to_a.empty?)
    loop_for_msg(s, 1)
    loop_for_msg(s, 2)
    assert(done_q.empty?)
    s.run_bg
    Timeout::timeout(5) do
      rv = done_q.pop
      assert_equal([["foo", 61]], rv)
    end
    s.stop
  end
end

class SimpleAgent
  include Bud

  state do
    channel :chn, [:@addr, :val]
    scratch :input_t, chn.schema
    table :log, chn.schema
  end

  bloom do
    chn <~ input_t
  end
end

class TestChannelFilter < MiniTest::Unit::TestCase
  def test_filter_drop
    f = lambda do |tbl_name, tups|
      return [tups, []] unless tbl_name == :chn
      res = []
      tups.each do |t|
        res << t if t[0][1] == 3
      end
      return [res, []]
    end

    src = SimpleAgent.new
    dst = SimpleAgent.new(:channel_filter => f)
    src.run_bg
    dst.run_bg

    q = Queue.new
    dst.register_callback(:chn) do |t|
      assert_equal([[dst.ip_port, 3]], t.to_a.sort)
      q.push(true)
    end

    (0..25).each do |i|
      src.sync_do {
        src.input_t <+ [[dst.ip_port, i]]
      }
    end

    q.pop
    src.stop
    dst.stop
  end

  def test_filter_batch
    f = lambda do |tbl_name, tups|
      return [tups, []] unless tbl_name == :chn
      if tups.size >= 12
        return [tups, []]
      else
        return [[], tups]
      end
    end

    src = SimpleAgent.new
    dst = SimpleAgent.new(:channel_filter => f)
    src.run_bg
    dst.run_bg

    q = Queue.new
    dst.register_callback(:chn) do |t|
      assert_equal(12, t.length)
      q.push(true)
    end

    (0..11).each do |i|
      src.sync_do {
        src.input_t <+ [[dst.ip_port, i]]
      }
    end

    q.pop
    src.stop
    dst.stop
  end
end

class UseSourceAddress
  include Bud

  state do
    channel :chn, [:@addr, :msg_id]
    scratch :in_t, chn.schema
    table :log, chn.schema
    table :done, chn.schema
  end

  bloom do
    chn <~ in_t
    chn <~ chn {|c| [c.source_addr, c.msg_id + 1] if c.msg_id < 10}
    log <= chn
    done <= chn {|c| c if c.msg_id >= 10}
  end
end

class SourceAddressTest < MiniTest::Unit::TestCase
  def test_source_addr
    u1 = UseSourceAddress.new
    u2 = UseSourceAddress.new

    u1.run_bg
    u2.run_bg

    q = Queue.new
    u2.register_callback(:done) do
      q.push(true)
    end
    u1.sync_do {
      u1.in_t <+ [[u2.ip_port, 0]]
    }

    q.pop

    u1.sync_do {
      vals = [1,3,5,7,9]
      res = vals.map {|v| [u1.ip_port, v]}
      assert_equal(res.sort, u1.log.to_a.sort)
    }
    u2.sync_do {
      vals = [0,2,4,6,8,10]
      res = vals.map {|v| [u2.ip_port, v]}
      assert_equal(res.sort, u2.log.to_a.sort)
    }


    u1.stop
    u2.stop
  end
end

class SimpleChannelUsage
  include Bud

  state do
    table :node, [:addr]
    scratch :msg_buf, [:v]
    channel :chn, [:@addr, :v]
    table :rbuf, msg_buf.schema
  end

  bloom do
    chn <~ (node * msg_buf).pairs {|n,m| n + m}
    rbuf <= chn.payloads
  end
end

class TestDisconnectChannels < MiniTest::Unit::TestCase
  def test_disconnect
    agents = Array.new(2) { SimpleChannelUsage.new }
    agents.each(&:run_bg)

    first, last = agents
    first.sync_do {
      first.node <+ [[last.ip_port]]
    }
    last.sync_do {
      last.node <+ [[first.ip_port]]
    }

    do_insert(first, 0)
    first.sync_do { first.disconnect_channels }
    do_insert(first, 10)
    first.sync_do { first.connect_channels }
    do_insert(first, 20)

    sleep 1

    last.sync_do {
      assert_equal([["foo0"], ["foo1"], ["foo2"],
                    ["foo20"], ["foo21"], ["foo22"]].to_set, last.rbuf.to_set)
    }

    agents.each(&:stop)
  end

  def do_insert(agent, offset)
    3.times do |i|
      agent.sync_do {
        agent.msg_buf <+ [["foo#{i + offset}"]]
      }
    end
  end
end
