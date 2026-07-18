[![Github Action (main)](https://github.com/cyber-dojo/spooler/actions/workflows/main.yml/badge.svg?branch=main)](https://github.com/cyber-dojo/spooler/actions)

- A docker-containerized microservice for [https://cyber-dojo.org](http://cyber-dojo.org).
- An HTTP [Ruby](https://www.ruby-lang.org) [Sinatra](http://sinatrarb.com/) web service that buffers web's write events and forwards them, durably and in order, to [saver](https://github.com/cyber-dojo/saver).
- Reads stay direct web->saver; only writes flow through the spooler.
- Demonstrates a [Kosli](https://www.kosli.com/) instrumented [GitHub CI workflow](.github/workflows/main.yml).
- The design, rationale, and staged rollout are in [docs/adr-async-writes-via-spooler.md](docs/adr-async-writes-via-spooler.md).

> Status: under active development. The service is not yet deployed. The
> deployment terraform and the aws-beta step of the CI workflow are still to
> come (see ADR section 8), and the coverage gates are expected to fail until
> the code is fully exercised.

# Development

There are two sets of tests:
- server: these run from inside the spooler container
- client: these run from outside the spooler container, making api calls only

```bash
# Build the images
$ make {image_server|image_client}

# Run all tests
$ make {test_server|test_client}

# Run only tests whose id58 matches an identifier
$ make {test_server|test_client} tid=Cp0002

# Check test metrics
$ make {metrics_test_server|metrics_test_client}

# Check coverage metrics
$ make {metrics_coverage_server|metrics_coverage_client}
```

# API

## Probe API

* GET alive?
* GET ready?
* GET sha

## Write pass-through API

Each POST is relayed to saver verbatim, including a non-2xx status (ADR B1).
These are saver's per-kata event writes; reads are not routed through the
spooler.

* POST kata_file_create
* POST kata_file_delete
* POST kata_file_rename
* POST kata_file_edit
* POST kata_ran_tests
* POST kata_predicted_right
* POST kata_predicted_wrong
* POST kata_reverted
* POST kata_checked_out

# Screenshots

![cyber-dojo.org home page](https://github.com/cyber-dojo/cyber-dojo/blob/master/shared/home_page_snapshot.png)
