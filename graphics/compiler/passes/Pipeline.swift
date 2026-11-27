// SPDX-License-Identifier: BSD-3-Clause

// The standard pass order: promote memory to registers, scalarize (the
// defined point where vectors end), promote what the split exposed, then
// fold, propagate, merge and sweep until nothing changes, then contract
// products into sums (fused multiply-adds) and go again.

extension IRModule {
  /// Run the passes on every function. With `scalarize` false vectors stay.
  public mutating func optimize(scalarize: Bool = true) throws(CompileError) {
    for k in 0..<functions.count {
      functions[k].promoteAllocas()
      if scalarize {
        try functions[k].scalarize()
        functions[k].promoteAllocas()
      }
      var rounds = 0
      while rounds < 16 {
        rounds += 1
        var changed = false
        if functions[k].foldConstants() { changed = true }
        if functions[k].propagateCopies() { changed = true }
        if functions[k].eliminateCommonSubexpressions() { changed = true }
        if functions[k].eliminateDeadCode() { changed = true }
        // (Vertex and fragment shaders only: the compute shaders' listings are the board's golden ones.)
        let graphics = executionModel == 0 || executionModel == 4
        if graphics && functions[k].reduceStrength() { changed = true }
        if !changed && graphics && functions[k].contractMultiplyAdds() { changed = true }
        if !changed { break }
      }
    }
  }
}
