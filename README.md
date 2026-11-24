# Appcircle Set Environment Variable

This step sets environment value for given keys

Input Variables
- `$AC_ENV_KEYS`: Space-separated list of environment variable keys.
- `$AC_ENV_VALUE`: Environment variable value to set.

## Running tests

Requires [RSpec](https://rspec.info) gem and Ruby standard library (Coverage, Open3). No Gemfile or Bundler needed.

```bash
ruby test/test_main.rb
```

A coverage report is printed at the end of each run.
