use v5.36;
use feature 'signatures';
no warnings 'experimental::signatures';
use Future::AsyncAwait;
use PASGI::Server;

# A simple echo app
async sub echo_app ($scope, $receive, $send) {

    # Read full body
    my $event = await $receive->();
    my $body  = $event->{body} || 'no body';

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

# Instantiate and run
my $server = PASGI::Server->new(\&echo_app, port => 8080);
$server->run;
