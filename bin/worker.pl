#!/usr/bin/env perl

use strict;
use warnings;
use utf8;
use AnyEvent;
use Furl;
use JSON qw/decode_json/;
use Unruly;
use URL::Encode qw/url_encode_utf8/;

use constant {
    PYAZO_BASE_URL        => 'http://pyazo.hachiojipm.org/',
    IMAGE_SEARCH_BASE_URL => 'http://ajax.googleapis.com/ajax/services/search/images',
    NOT_FOUND_MESSAGE     => '画像無かったっぽい',
    ERROR_MESSAGE         => 'なんか調子悪いみたい',
};

my $furl = Furl->new(timeout => 10);

my $ur = Unruly->new(
    url  => 'http://yancha.hachiojipm.org',
    tags => {PUBLIC => 1}
);

$ur->login('fujita');

my $cv = AnyEvent->condvar;

$ur->run(sub {
    my ($client, $socket) = @_;
    $socket->on('user message' => sub {
        my ($socket_info, $message) = @_;

        my @tags = @{$message->{tags}};
        my $message_text = $message->{text};
        if ($message->{text} =~ /^(.+)の画像\s#/) {
            my $word = url_encode_utf8($1);
            my $res  = $furl->get(IMAGE_SEARCH_BASE_URL . qq{?q="$word"&v=1.0});
            unless ($res->is_success) {
                $ur->post(NOT_FOUND_MESSAGE, @tags);
                return;
            }

            my $res_json = decode_json($res->content)->{responseData};
            if (my $image_url = $res_json->{results}->[0]->{url}) {
                my $res = $furl->post(
                    PYAZO_BASE_URL,
                    ['Content-Type' => "application/x-www-form-urlencoded"],
                    ['fileurl' => $image_url],
                );

                unless ($res->is_success) {
                    $ur->post(ERROR_MESSAGE, @tags);
                    return;
                }
                $ur->post($res->{content}, @tags);
            }
            else {
                $ur->post(NOT_FOUND_MESSAGE, @tags);
                return;
            }
        }
    });
});

$cv->wait;
