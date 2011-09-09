require 'rubygems'
require 'open-uri'
require 'json'
require 'cgi'
require 'socket'

require 'rhuidean'
require 'sinatra/base'
require 'hashie'

#############
# functions #
#############

TCP_PORT  = 3456
HTTP_PORT = 6543

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

def announce_commits(info)
    # Grab the branch name
    branch = info.ref.split('/')[-1]

    $branch = branch

    # Go over each commit and report it
    info.commits.each do |commit|
        # Gather some info to report
        url     = minify(commit.url)
        author  = commit.author.username
        sha1    = commit.id[0 ... 7]
        message = commit.message.split("\n")[0]

        # Gather info about the files changed
        changed  = []
        changed += commit.modified if commit.modified
        changed += commit.added    if commit.added
        changed += commit.removed  if commit.removed

        dirs = files = []
        sep  = File::SEPARATOR

        if changed.length == 1
            # If just one file was changed, list the filename
            files = changed[0]

            strfiles = strdirs = nil
        else
            # Just report number of files and dirs
            dirs     = changed.grep(/\//)
            dirfiles = dirs.collect { |dir| dir.split(sep)[-1] }
            files    = changed - dirs
            files   += dirfiles

            # Whittle out duplicates
            dirs.collect! { |fp| fp.split(sep)[0 ... -1].join(sep) }.uniq!

            dirs  = dirs.length
            files = files.length

            strfiles = "file%s" % [files > 1 ? 's' : '']
            strdirs  = "dir%s"  % [dirs  > 1 ? 's' : '']
        end

        # Build the string to send to IRC
        str  = "commit \002#{sha1}\002: \0033#{author}\003 * \0037#{branch}\003"

        if strfiles and strdirs
            str += " / (#{files} #{strfiles} in #{dirs} #{strdirs}): "
        else
            str += " / #{files}: "
        end

        str += "#{message} - #{url}"

        $clients.each do |client|
            begin
                client.socket.write_nonblock("PRIVMSG #malkier :#{str}\r\n")
            rescue IO::WaitWritable
                IO.select([], [client.socket])
                retry
            end
        end
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

# Op everyone on the testnet
$clients[1].on(:JOIN) do |m|
    m.client.mode('#malkier', "+o #{m.origin_nick}") if m.target == '#malkier'
end

# Keep track of open and closed issues
$open_issues   = get_issues :open
$closed_issues = get_issues :closed

# Only report when the commit is on the develop branch
$branch = nil

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

#######
# tcp #
#######

# Make our TCP server
begin
    $server = TCPServer.new('0.0.0.0', TCP_PORT)
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
        data.chomp!
        addr = sock.peeraddr[-1]
        sock.close
    end

    # Tokenize
    str    = nil
    tokens = data.split(' ')

    case tokens[0]
    when 'ci:success'
        str  = "commit \002#{tokens[1]}\002 \0033succeeded\003: "
        str += "#{tokens[2 ... -3].join(' ')} (#{tokens[-2].to_i.round}s)"
    when 'ci:failure'
        str  = "commit \002#{tokens[1]}\002 \0034failed\003: "
        str += "#{tokens[2 ... -3].join(' ')} (#{tokens[-2].to_i.round}s) "
        str += "- http://is.gd/qAPyRb"
    when 'rakaur:say'
        str = tokens[1 .. -1].join(' ')
    when 'rakaur:die'
        return unless addr == '127.0.0.1'
        $clients.each { |client| client.thread.kill }
        $server_thread.kill
        $httpd_thread.kill
    else
        p data
        return
    end

    # Only report on the latest commit
    return if $branch and $branch != 'develop' and $branch != 'master'

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

#########
# httpd #
#########

class HTTPd < Sinatra::Base
    set :port, HTTP_PORT
    post '/' do
        push = Hashie::Mash.new(JSON(params[:payload]))
        announce_commits(push) if push.repository.name == 'kythera'
    end
end

###########
# threads #
###########

# Start the IRC client
$clients.each { |client| client.thread = Thread.new { client.io_loop } }

# Poll our TCP server
$server_thread = Thread.new { loop { server_loop } }

# Start the HTTPd in the main thread
HTTPd.run!
