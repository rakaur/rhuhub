require 'rubygems'
require 'open-uri'
require 'json'

require 'rhuidean'
require 'hashie'

def curl(url)
  open(url) { |f| f.read }
end

def get_issues(type = :open)
  b = curl("http://github.com/api/v2/json/issues/list/malkier/kythera/#{type}")
  Hashie::Mash.new(JSON(b)).issues
end

def announce_issues(issues)
    issues.each do |issue|
        number = issue.number
        title  = issue.title
        user   = issue.user
        url    = issue.html_url
        state  = issue.state
        labels = "[#{issue.labels.join(', ')}]"

        if issue.labels.empty?
            str = "##{number} (#{state}): #{title} - #{url}"
        else
            str = "##{number} (#{state}): #{title} #{labels} - #{url}"
        end

        $client.privmsg('#malkier', str)
    end
end

$open_issues   = get_issues :open
$closed_issues = get_issues :closed

# Make our client
$client = IRC::Client.new do |c|
    c.nickname  = 'kythera'
    c.username  = 'rhuidean'
    c.realname  = "a facet of someone else's imagination"
    c.server    = 'ircd.malkier.net'
    c.port      = 6667
    c.logger    = Logger.new($stdout)
    c.log_level = :info
end

$client.on(IRC::Numeric::RPL_ENDOFMOTD) { |m| $client.join('#malkier') }

# This is the timer to monitor issues
IRC::Timer.every(60) do
    issues = get_issues
    new_issues = issues - $open_issues

    announce_issues(new_issues)

    $open_issues = issues
end

IRC::Timer.every(60) do
    issues = get_issues(:closed)
    new_issues = issues - $closed_issues

    announce_issues(new_issues)

    $closed_issues = issues
end

# Now we actually start up the client, and wait for it to exit
$client.thread = Thread.new { $client.io_loop }
$client.thread.join
