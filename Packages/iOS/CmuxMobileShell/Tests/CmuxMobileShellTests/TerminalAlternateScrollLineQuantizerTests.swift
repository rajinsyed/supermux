import Testing

@testable import CmuxMobileShell

@Suite("Alternate-screen scroll line quantizer")
struct TerminalAlternateScrollLineQuantizerTests {
    @Test("fractional packets accumulate into whole lines")
    func fractionsAccumulate() {
        var quantizer = TerminalAlternateScrollLineQuantizer()

        // The traced slow-drag stream at 0.25×: ~0.06-line packets. With
        // per-packet host rounding this scrolled ~10 lines; quantized it
        // must scroll 0 until the accumulated travel crosses a full line.
        var emitted = 0.0
        for _ in 0..<10 {
            emitted += quantizer.emit(lines: 0.06)
        }
        #expect(emitted == 0)

        // Seven more packets cross 1.0 total; exactly one line emits.
        for _ in 0..<7 {
            emitted += quantizer.emit(lines: 0.06)
        }
        #expect(emitted == 1)
    }

    @Test("whole lines pass through with the fraction carried")
    func wholeLinesPassThrough() {
        var quantizer = TerminalAlternateScrollLineQuantizer()

        #expect(quantizer.emit(lines: 2.5) == 2)
        // The 0.5 carry joins the next packet (0.5 + 0.75 = 1.25 → 1).
        #expect(quantizer.emit(lines: 0.75) == 1)
    }

    @Test("reversal unwinds the carry through signed accumulation")
    func reversalUnwindsCarry() {
        var quantizer = TerminalAlternateScrollLineQuantizer()

        #expect(quantizer.emit(lines: 0.7) == 0)
        // Reversing past the carry emits in the new direction only after a
        // net whole line: 0.7 - 1.8 = -1.1 → -1 with -0.1 carried.
        #expect(quantizer.emit(lines: -1.8) == -1)
        #expect(quantizer.emit(lines: -0.9) == -1)
    }

    @Test("non-finite input emits nothing and preserves the carry")
    func nonFiniteIsIgnored() {
        var quantizer = TerminalAlternateScrollLineQuantizer()

        #expect(quantizer.emit(lines: 0.5) == 0)
        #expect(quantizer.emit(lines: .nan) == 0)
        #expect(quantizer.emit(lines: 0.5) == 1)
    }

    @Test("speed preference now scales lines per unit of finger travel")
    func speedScalesEmittedLines() {
        // The same 26-packet fast drag at 1× vs 0.25×. Quantized delivery
        // must differ by ~4×, unlike the per-packet rounding it replaces
        // (which emitted one line per packet at every speed).
        func emitted(atSpeed speed: Double) -> Double {
            var quantizer = TerminalAlternateScrollLineQuantizer()
            var total = 0.0
            for _ in 0..<26 {
                total += abs(quantizer.emit(lines: -0.85 * speed))
            }
            return total
        }

        let full = emitted(atSpeed: 1.0)
        let quarter = emitted(atSpeed: 0.25)
        #expect(full >= 21)
        #expect(quarter <= 6)
    }
}
