require 'json'
require 'shellwords'
require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'

  gem 'jira-ruby'
  gem 'pandoc-ruby'
end

class ExportIssue
  JIRA_URL = ENV['JIRA_BASE_URL']

  # JIRA statuses for closed tickets
  CLOSED = Set.new(%w[Cancelled Closed]).freeze

  # Only query the fields we need to reduce amount of data that we fetch
  FIELDS = %i[
    key
    issuetype
    summary
    description
    status
    resolution
    created
  ].freeze

  def initialize
    options = {
      site: JIRA_URL,
      context_path: '',
      auth_type: :basic,
      username: ENV['JIRA_USER_EMAIL'],
      password: ENV['JIRA_API_TOKEN']
    }

    @client = JIRA::Client.new(options)
  end

  def export(key)
    raise ArgumentError, "Invalid JIRA key '#{key}'" unless key.match?('[A-Z]+-[0-9]+')

    puts "Exporting '#{key}'"

    # This raises if the key doesn't exist
    issue = @client.Issue.jql("key = #{key}", fields: FIELDS, max_results: 1).first

    gh = transform(issue)
    labels = gh["labels"].join(',')

    Tempfile.create do |f|
      f.write(gh["body"])
      f.flush

      output = %x{gh issue create --title #{Shellwords.escape(gh["title"])} --body-file #{f.path} --label #{labels}}
      if $? != 0
        puts "Failed to create issue"
        puts
        puts output
        exit(1)
      end

      data = output.match(%r{^https://github.com/.*$})
      unless data
        puts "Failed to match github URL"
        puts
        puts output
        exit(1)
      end

      url = data[0]
      puts "Created issue: #{url}"

      if gh["closed"]
        output = %x{gh issue close #{url}}
        if $? != 0
          puts "Failed to close issue"
          puts
          puts output
          exit(1)
        end

        puts "Closed issue: #{url}"
      end

      # Add comment
      comment = issue.comments.build
      comment.save!(body: "Migrated issue to #{url}")
    end
  end

  private

  def transform(issue)
    created = DateTime.parse(issue.created).strftime('%F %r')
    title = "(#{issue.key}) #{issue.summary}"
    body = <<~END
    This issue was originally created on #{created} in #{JIRA_URL}/browse/#{CGI.escapeHTML(issue.key)}

    #{markdownify(issue.description)}
    END

    labels = ['from-jira']
    case issue.issuetype.name
    when 'Bug'
      labels << 'bug'
    when 'Story'
      labels << 'enhancement'
    else
      # ignore tasks, epics
    end

    if issue.status.name == 'Cancelled'
      case issue.resolution["name"]
      when 'Duplicate'
        labels << 'duplicate'
      when 'Incomplete', 'Declined', "Won't Do", "Won't Fix"
        labels << 'wontfix'
      else
        # ignore
      end
    end

    {
      'title' => title,
      'body' => body,
      'labels' => labels,
      'closed' => CLOSED.include?(issue.status.name)
    }
  end

  def markdownify(text)
    return '' unless text

    PandocRuby.convert(text, from: :jira, to: :gfm)
  end
end

exporter = ExportIssue.new
exporter.export(ARGV[0])
