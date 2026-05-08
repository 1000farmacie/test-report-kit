FROM ruby:3.3-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      git \
      build-essential \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY Gemfile test_report_kit.gemspec ./
COPY lib/test_report_kit/version.rb lib/test_report_kit/version.rb

RUN bundle install

COPY . .

CMD ["bundle", "exec", "rspec"]
