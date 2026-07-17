
all_server: image_server test_server metrics_test_server metrics_coverage_server

image_server:
	@${PWD}/bin/build_image.sh server

test_server:
	@${PWD}/bin/run_tests.sh server

metrics_test_server:
	@${PWD}/bin/check_test_metrics.sh server

metrics_coverage_server:
	@${PWD}/bin/check_coverage_metrics.sh server
