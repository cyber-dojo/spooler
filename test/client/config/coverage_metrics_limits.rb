
# Deployment bar: full coverage (missed == 0) for both source and test code.
# The total caps only guard against unnoticed growth; the missed limits are
# the real gate.
def metrics
  [
    [ nil ],
    [ 'test.lines.total'    , '<=',  79 ],
    [ 'test.lines.missed'   , '<=',   0 ],
    [ 'test.branches.total' , '<=',   0 ],
    [ 'test.branches.missed', '<=',   0 ],
    [ nil ],
    [ 'code.lines.total'    , '<=', 113 ],
    [ 'code.lines.missed'   , '<=',   0 ],
    [ 'code.branches.total' , '<=',   2 ],
    [ 'code.branches.missed', '<=',   0 ],
  ]
end
