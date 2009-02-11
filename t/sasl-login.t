#!/usr/bin/perl
use strict;
use warnings;
use Test::More tests => 26;
use lib 't/lib';

require 'djabberd-test.pl';

use Authen::SASL 'Perl';

my $login_and_be = sub {
    my ($pa, $pb, $sasl) = @_;

    $pa->sasl_login($sasl);
    $pb->login;
    $pa->send_xml("<presence/>");
    $pb->send_xml("<presence/>");

    $pa->send_xml("<iq type='get' id='pa1' to='$pb'><x/></iq>");
    like($pb->recv_xml, qr/id=.pa./, "pb got pa's iq");
    $pb->send_xml("<iq type='get' id='pb1' to='$pa'><x/></iq>");
    like($pa->recv_xml, qr/id=.pb./, "pb got pa's iq");
};

## login successes
{
    for my $mechanism (qw/PLAIN LOGIN DIGEST-MD5/) {
        two_parties(sub {
            my ($pa, $pb) = @_;

            my $sasl = Authen::SASL->new(
                mechanism => $mechanism,
                callback  => {
                    pass => sub { $pa->password },
                    user => sub { $pa->{name}   },
                },
            );

            $login_and_be->($pa, $pb, $sasl);
        });
    }
}

# a server available for tests using the common setup
my $server = Test::DJabberd::Server->new(id => 1);
$server->start;

## login failures
{
    for my $mechanism (qw/PLAIN LOGIN DIGEST-MD5/) {
        my $sasl = Authen::SASL->new(
            mechanism => $mechanism,
            callback  => {
                pass => "incorrect pass",
                user => "partya",
            },
        );

        my $pa = Test::DJabberd::Client->new(server => $server, name => "partya");
        eval { $pa->sasl_login($sasl) };
        my $err = $@;
        ok $err, "login failure";
        like $err, qr{failure.*<not-authorized/>};
    }
}

## abort
{
    my $sasl = Authen::SASL->new(
        mechanism => "DIGEST-MD5",
        callback  => {
            pass => "incorrect pass",
            user => "partya",
        },
    );

    my $pa = Test::DJabberd::Client->new(server => $server, name => "partya");
    my $response = $pa->abort_sasl_login($sasl);
    like $response, qr{failure.*<aborted/>};
}

## invalid mechanism
{
    my $strong_server = Test::DJabberd::Server->new( id => 2, );
    my $sasl_plugin =  DJabberd::SASL::AuthenSASL->new(
        mechanisms => "DIGEST-MD5", 
        optional   => "yes"
    );

    my $plugins = [ @{$strong_server->std_plugins_sans_sasl}, $sasl_plugin ];

    $strong_server->start($plugins);
    my $sasl = Authen::SASL->new(
        mechanism => "PLAIN",
        callback  => {
            pass => "incorrect pass",
            user => "partya",
        },
    );

    my $pa = Test::DJabberd::Client->new(server => $strong_server, name => "partya");
    eval { $pa->sasl_login($sasl) };
    my $err = $@;
    like $err, qr{failure.*<invalid-mechanism/>};
    $strong_server->kill;
}

## someone binding without authenticating
{
    my $pa = Test::DJabberd::Client->new(server => $server, name => "partya");
    $pa->connect or die "Failed to connect";
    my $sock = $pa->{sock};

    my $fail = sub {
        my $r = $pa->recv_xml;
        like $r, qr{<iq .* type='error'>.*</iq>}sm;
        like $r, qr{<error type='cancel'>.*</error>}sm;
        like $r, qr{<not-allowed xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/>}sm;
    };

    print $sock "<iq id='bind_1' type='set'>
                    <bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'/>
                </iq>";
    $fail->();

    print $sock '<auth xmlns="urn:ietf:params:xml:ns:xmpp-sasl" mechanism="DIGEST-MD5" />';
    $pa->recv_xml;
    print $sock "<iq id='bind_1' type='set'>
                    <bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'/>
                </iq>";
    $fail->();
}

$server->kill;