use Test::Most;
use IO::Socket::INET;
use PASGI::Server;

# Fork to run the server in a child process.
my $pid = fork();
die "Fork failed: $!" unless defined $pid;

if ($pid == 0) {
    # Child process: start the PASGI server.
    my $server = PASGI::Server->new(
        app => sub {
            my ($scope, $receive, $send) = @_;
            return $send->({
                type    => 'http.response.start',
                status  => 200,
                headers => [ ['content-type', 'text/plain'] ],
            })->then(sub {
                return $send->({
                    type => 'http.response.body',
                    body => "Hello, World!",
                });
            });
        },
        host => '127.0.0.1',
        port => 8080,
    );
    $server->start;
    exit(0);
}

# Parent process: wait a moment for the server to start.
sleep 1;

# Create a client socket and send an HTTP GET request.
my $socket = IO::Socket::INET->new(
    PeerAddr => '127.0.0.1',
    PeerPort => 8080,
    Proto    => 'tcp',
    Timeout  => 5,
) or die "Could not connect: $!";

print $socket "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n";

# Read the response.
my $response = '';
$socket->recv($response, 1024);
close($socket);

like($response, qr/Hello, World!/, 'Server response contains "Hello, World!"');

# Clean up: kill the child server process.
kill 'TERM', $pid;
waitpid($pid, 0);

pass("Server process terminated");

done_testing;
