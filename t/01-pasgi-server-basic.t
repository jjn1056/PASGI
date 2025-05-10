use v5.36;
use feature 'signatures';
no warnings 'experimental::signatures';

use Test2::V0;
use IO::Async::Loop;
use IO::Async::Test;
use Future::AsyncAwait;
use PASGI::Server;

my $CRLF = "\x0d\x0a";
my $loop = IO::Async::Loop->new();
testing_loop( $loop );

# A simple echo app
async sub echo_app ($scope, $receive, $send) {

    # check scope
    die "Can only do HTTP" unless $scope->{type} eq 'http';

    # Read full body
    my $event = await $receive->();
    my $body  = $event->{body} // '';

    # Start response
    await $send->({
        type    => 'http.response.start',
        status  => 200,
        headers => [[ 'content-type', 'text/plain; charset=utf-8' ]],
    });

    # Send echo body
    await $send->({
        type      => 'http.response.body',
        body      => "You said: $body",
        more_body => 0,
    });
}

my $server = PASGI::Server->new(\&echo_app, port => 8080)->server;

$loop->add( $server );
$server->listen(
   addr => { family => "inet", socktype => "stream", ip => "127.0.0.1" },
   on_listen_error => sub { die "Test failed early - $_[-1]" },
);
my $C = IO::Socket::INET->new(
   PeerHost => $server->read_handle->sockhost,
   PeerPort => $server->read_handle->sockport,
) or die "Cannot connect - $@";

subtest 'Basic Echo' => sub {
  my $request = HTTP::Request->new(POST => '/', ['Content-Type' => 'text/plain; charset=UTF-8', 'Content-Length' => 3], "abc");
  $request->protocol('HTTP/1.1');
  my $string = $request->as_string($CRLF);

  $C->syswrite($string);

  my $buffer = ""; wait_for_stream { length $buffer >= length "You said: abc"} $C => $buffer;
  ok my $res = HTTP::Response->parse($buffer);

  is $res->content, 'You said: abc';
};

done_testing;

