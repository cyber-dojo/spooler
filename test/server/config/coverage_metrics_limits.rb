
# Deployment bar: full coverage (missed == 0) for both source and test code.
# It is expected to FAIL in these early stages (dead code paths not yet
# exercised) and must pass before deployment. The total caps only guard
# against unnoticed growth; the missed limits are the real gate.
def metrics
  [
    [ nil ],
    [ 'test.lines.total'    , '<=', 480 ],
    [ 'test.lines.missed'   , '<=',   0 ],
    [ 'test.branches.total' , '<=',   6 ],
    [ 'test.branches.missed', '<=',   0 ],
    [ nil ],
    [ 'code.lines.total'    , '<=', 262 ],
    [ 'code.lines.missed'   , '<=',   0 ],
    [ 'code.branches.total' , '<=',  17 ],
    [ 'code.branches.missed', '<=',   0 ],
  ]
end
