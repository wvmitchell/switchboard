# frozen_string_literal: true

module Switchboard
  # A QR encoder for one job: drawing a remote-link URL in the sidebar (zero gems, so
  # no rqrcode). Byte mode, error correction M, versions 1-6 only: 6-M holds 106 bytes
  # and a link URL is at most 95 (RemoteLink::BRIDGE_ID), and stopping before 7 means
  # there are no version-information blocks to place. Pure: a string in, rows of
  # booleans (true = dark module) out, no quiet zone; anything too long is nil.
  module QR
    # Per version at level M: [EC codewords per block, data codewords per block].
    BLOCKS = {
      1 => [10, [16]],
      2 => [16, [28]],
      3 => [26, [44]],
      4 => [18, [32, 32]],
      5 => [24, [43, 43]],
      6 => [16, [27, 27, 27, 27]]
    }.freeze
    FORMAT_M = 0b00 # the EC-level field of the format bits (M is 00)

    MASKS = [
      ->(x, y) { (x + y).even? },
      ->(_x, y) { y.even? },
      ->(x, _y) { (x % 3).zero? },
      ->(x, y) { ((x + y) % 3).zero? },
      ->(x, y) { ((x / 3) + (y / 2)).even? },
      ->(x, y) { ((x * y) % 2) + ((x * y) % 3) == 0 },
      ->(x, y) { (((x * y) % 2) + ((x * y) % 3)).even? },
      ->(x, y) { (((x + y) % 2) + ((x * y) % 3)).even? }
    ].freeze

    FINDER_LIKE = [[true, false, true, true, true, false, true, false, false, false, false],
                   [false, false, false, false, true, false, true, true, true, false, true]].freeze

    module_function

    # `mask:` forces one of the 8 masks (the fixtures pin each one); nil picks the
    # lowest penalty, ties to the lower mask number.
    def matrix(string, mask: nil)
      data = string.to_s.b
      version = (1..6).find { |v| capacity(v) >= data.bytesize }
      return nil unless version

      grid, function = base(version)
      place(grid, function, codewords(data, version))
      masks = mask ? [mask] : (0...MASKS.size).to_a
      masks.map { |m| masked(grid, function, m) }.min_by { |g| penalty(g) }
    end

    # Bytes a version holds in byte mode: 4 mode bits + an 8-bit count, then data.
    def capacity(version)
      ((BLOCKS[version][1].sum * 8) - 12) / 8
    end

    def size(version) = 17 + (4 * version)

    # Data bits → padded codewords → per-block Reed-Solomon → interleaved stream.
    def codewords(data, version)
      ec_len, block_lens = BLOCKS[version]
      bits = +"0100" << format("%08b", data.bytesize) << data.unpack1("B*")
      total = block_lens.sum * 8
      bits << ("0" * [4, total - bits.size].min)
      bits << ("0" * (-bits.size % 8))
      bytes = bits.scan(/.{8}/).map { |b| b.to_i(2) }
      pads = [0xEC, 0x11].cycle
      bytes << pads.next while bytes.size < block_lens.sum

      blocks = block_lens.map { |n| bytes.shift(n) }
      ecs = blocks.map { |b| remainder(b, ec_len) }
      interleave(blocks) + interleave(ecs)
    end

    def interleave(blocks)
      (0...blocks.map(&:size).max).flat_map { |i| blocks.filter_map { |b| b[i] } }
    end

    # The Reed-Solomon EC codewords: data × x^degree mod the generator polynomial.
    def remainder(data, degree)
      divisor = generator(degree)
      result = Array.new(degree, 0)
      data.each do |byte|
        factor = byte ^ result.shift
        result << 0
        divisor.each_with_index { |coef, i| result[i] ^= gf_mul(coef, factor) }
      end
      result
    end

    # Generator (x - α^0)(x - α^1)…(x - α^(degree-1)), highest coefficient first, the
    # leading 1 left off.
    def generator(degree)
      result = Array.new(degree - 1, 0) << 1
      root = 1
      degree.times do
        degree.times do |j|
          result[j] = gf_mul(result[j], root)
          result[j] ^= result[j + 1] if j + 1 < degree
        end
        root = gf_mul(root, 0x02)
      end
      result
    end

    # Multiplication in GF(2^8) modulo the QR polynomial x^8 + x^4 + x^3 + x^2 + 1.
    def gf_mul(x, y)
      z = 0
      7.downto(0) do |i|
        z = (z << 1) ^ ((z >> 7) * 0x11D)
        z ^= ((y >> i) & 1) * x
      end
      z
    end

    # The fixed patterns, plus a function-module map so data and masks skip them.
    def base(version)
      n = size(version)
      grid = Array.new(n) { Array.new(n, false) }
      function = Array.new(n) { Array.new(n, false) }
      set = lambda do |x, y, dark|
        grid[y][x] = dark
        function[y][x] = true
      end

      n.times do |i| # timing
        set.call(6, i, i.even?)
        set.call(i, 6, i.even?)
      end
      [[3, 3], [n - 4, 3], [3, n - 4]].each do |cx, cy| # finders + separators
        (-4..4).each do |dy|
          (-4..4).each do |dx|
            x = cx + dx
            y = cy + dy
            next unless x.between?(0, n - 1) && y.between?(0, n - 1)

            dist = [dx.abs, dy.abs].max
            set.call(x, y, dist != 2 && dist != 4)
          end
        end
      end
      if version > 1 # one alignment pattern; the other candidates overlap the finders
        c = n - 7
        (-2..2).each { |dy| (-2..2).each { |dx| set.call(c + dx, c + dy, [dx.abs, dy.abs].max != 1) } }
      end
      draw_format(grid, function, 0) # reserve the format areas
      [grid, function]
    end

    # Both copies of the 15 format bits (EC level + mask, BCH-protected), and the
    # always-dark module.
    def draw_format(grid, function, mask)
      n = grid.size
      data = (FORMAT_M << 3) | mask
      rem = data
      10.times { rem = (rem << 1) ^ ((rem >> 9) * 0x537) }
      bits = ((data << 10) | rem) ^ 0x5412
      set = lambda do |x, y, i|
        grid[y][x] = bits[i] == 1
        function[y][x] = true
      end

      (0..5).each { |i| set.call(8, i, i) }
      set.call(8, 7, 6)
      set.call(8, 8, 7)
      set.call(7, 8, 8)
      (9..14).each { |i| set.call(14 - i, 8, i) }
      (0..7).each { |i| set.call(n - 1 - i, 8, i) }
      (8..14).each { |i| set.call(8, n - 15 + i, i) }
      grid[n - 8][8] = true
      function[n - 8][8] = true
    end

    # The zigzag: two-column strips from the right edge, alternating up and down,
    # stepping over the vertical timing column. Leftover remainder bits stay light.
    def place(grid, function, words)
      n = grid.size
      bits = words.pack("C*").unpack1("B*")
      i = 0
      right = n - 1
      while right >= 1
        right = 5 if right == 6
        upward = ((right + 1) & 2).zero?
        n.times do |vert|
          y = upward ? n - 1 - vert : vert
          [right, right - 1].each do |x|
            next if function[y][x] || i >= bits.size

            grid[y][x] = bits[i] == "1"
            i += 1
          end
        end
        right -= 2
      end
    end

    def masked(grid, function, mask)
      rule = MASKS[mask]
      out = grid.each_with_index.map do |row, y|
        row.each_with_index.map { |dark, x| function[y][x] ? dark : (dark ^ rule.call(x, y)) }
      end
      draw_format(out, function.map(&:dup), mask)
      out
    end

    # The spec's four mask-penalty rules, summed. Each is public so it can be tested
    # on a small hand-worked grid.
    def penalty(grid)
      penalty_runs(grid) + penalty_blocks(grid) + penalty_finders(grid) + penalty_balance(grid)
    end

    # N1: a run of 5+ same-colored modules in a row or column scores 3, +1 per extra.
    def penalty_runs(grid)
      lines(grid).sum do |line|
        line.chunk_while { |a, b| a == b }.sum { |run| run.size >= 5 ? run.size - 2 : 0 }
      end
    end

    # N2: every 2×2 block of one color scores 3 (overlapping blocks all count).
    def penalty_blocks(grid)
      (0...grid.size - 1).sum do |y|
        (0...grid[y].size - 1).count do |x|
          c = grid[y][x]
          grid[y][x + 1] == c && grid[y + 1][x] == c && grid[y + 1][x + 1] == c
        end * 3
      end
    end

    # N3: a finder-like 1:1:3:1:1 run with 4 light modules on one side scores 40. Only
    # modules inside the symbol count (encoders differ on the quiet zone; libqrencode#220).
    def penalty_finders(grid)
      lines(grid).sum do |line|
        line.each_cons(11).count { |w| FINDER_LIKE.include?(w) } * 40
      end
    end

    # N4: 10 per full 5% the dark share strays from 50%.
    def penalty_balance(grid)
      total = grid.sum(&:size)
      dark = grid.sum { |row| row.count(true) }
      ((dark * 20) - (total * 10)).abs / total * 10
    end

    def lines(grid) = grid + grid.transpose
  end
end
