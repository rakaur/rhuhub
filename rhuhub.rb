require 'rubygems'
require 'open-uri'
require 'json'
require 'cgi'
require 'socket'

require 'rhuidean'
require 'hashie'

#############
# functions #
#############

def curl(url)
    open(url) { |f| f.read }
end

def get_issues(type = :open)
    url = "http://github.com/api/v2/json/issues/list/malkier/kythera/#{type}"

    Hashie::Mash.new(JSON(curl(url))).issues
end

def minify(longurl)
    curl("http://is.gd/create.php?format=simple&url=#{CGI.escape(longurl)}")
end

def announce_issues(issues)
    issues.each do |issue|
        number = issue.number
        title  = issue.title
        user   = issue.user
        url    = minify(issue.html_url)
        state  = issue.state
        labels = "[#{issue.labels.join(', ')}]"

        if issue.labels.empty?
            str = "##{number} (#{state}): #{title} - #{url}"
        else
            str = "##{number} (#{state}): #{title} #{labels} - #{url}"
        end

        $clients.each { |client| client.privmsg('#malkier', str) }
    end
end

#######
# app #
#######

$clients = []

# Make our IRC client
$clients << IRC::Client.new do |c|
    c.nickname  = 'kythera'
    c.username  = 'rhuidean'
    c.realname  = "a facet of someone else's imagination"
    c.server    = 'moridin.ericw.org'
    c.port      = 6667
    c.logger    = Logger.new($stdout)
    c.log_level = :info
end

$clients << IRC::Client.new do |c|
    c.nickname  = 'kythera'
    c.username  = 'rhuidean'
    c.realname  = "a facet of someone else's imagination"
    c.server    = 'moridin.ericw.org'
    c.port      = 6699
    c.logger    = Logger.new($stdout)
    c.log_level = :info
end

# Join channels on connect
$clients.each do |client|
    client.on(IRC::Numeric::RPL_ENDOFMOTD) do |m|
        client.join('#malkier')
    end
end

# Keep track of open and closed issues
$open_issues   = get_issues :open
$closed_issues = get_issues :closed

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

# Make our TCP server
begin
    $server = TCPServer.new('0.0.0.0', 3456)
rescue Exception => err
    puts "Couldn't open TCP socket: #{err}"
    abort
end

def server_loop
    # Listen for an incoming connection
    begin
        sock = $server.accept_nonblock
    rescue IO::WaitReadable
        IO.select([$server])
        retry
    end

    # OK, we have a connection, now read from it and close it
    begin
        data = sock.read_nonblock(8192)
    rescue IO::WaitReadable
        IO.select([sock])
        retry
    else
        sock.close
    end

    # Tokenize
    str    = nil
    tokens = data.chomp.split(' ')

    case tokens[0]
    when 'ci:success'
        str = "CI: commit #{tokens[1]} succeeded: #{tokens[2 ... -3].join(' ')} (#{tokens[-2].to_i.round}s)"
    when 'ci:failure'
        str = "CI: commit #{tokens[1]} failed: #{tokens[2 ... -3].join(' ')} (#{tokens[-2].to_i.round}s) - http://is.gd/qAPyRb"
    when 'rakaur:say'
        str = tokens[1 .. -1].join(' ')
    else
        return
    end

    # OK, now send the read bytes to IRC
    $clients.each do |client|
        begin
            client.socket.write_nonblock("PRIVMSG #malkier :#{str}\r\n")
        rescue IO::WaitWritable
            IO.select([], [client.socket])
            retry
        end
    end
end

###########
# threads #
###########

# Start the IRC client
$clients.each { |client| client.thread = Thread.new { client.io_loop } }

# Poll our TCP server
server_thread = Thread.new { loop { server_loop } }

server_thread.join
$clients.each { |client| client.thread.join }
