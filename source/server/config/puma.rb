#!/usr/bin/env puma

require 'etc'

environment 'production'
rackup "#{__dir__}/config.ru"

# The spooler is a singleton (ADR section 8): its embedded SQLite store is
# single-writer, so the service must run as one task. Worker processes within
# that single task are fine; SQLite (WAL) serialises writes across them.

workers Etc.nprocessors
