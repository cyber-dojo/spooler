
# Deployment bar: full coverage (missed == 0) for both source and test code.
# The total caps only guard against unnoticed growth; the missed limits are
# the real gate.
def metrics
  [
    [ nil ],
    [ 'test.lines.total'    , '<=', 537 ],
    [ 'test.lines.missed'   , '<=',   0 ],
    [ 'test.branches.total' , '<=',   9 ],
    [ 'test.branches.missed', '<=',   0 ],
    [ nil ],
    [ 'code.lines.total'    , '<=', 268 ],
    [ 'code.lines.missed'   , '<=',   0 ],
    [ 'code.branches.total' , '<=',  13 ],
    [ 'code.branches.missed', '<=',   0 ],
  ]
end
