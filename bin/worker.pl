#!/usr/bin/env perl

use strict;
use warnings;
use utf8;
use AnyEvent;
use Furl;
use FindBin;
use JSON qw/decode_json/;
use Unruly;
use URL::Encode qw/url_encode_utf8/;

use constant {
    NOT_FOUND_MESSAGE     => '画像無かったっぽい',
    ERROR_MESSAGE         => 'なんか調子悪いみたい',
};

my $conf = do "$FindBin::Bin/../config.pl";
my $YANCHA_URL            = $conf->{YANCHA_URL};
my $PYAZO_BASE_URL        = $conf->{PYAZO_BASE_URL};
my $IMAGE_SEARCH_BASE_URL = $conf->{IMAGE_SEARCH_BASE_URL};

my $furl = Furl->new(timeout => 10);

my $ur = Unruly->new(
    url  => $YANCHA_URL,
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
        if ($message->{text} =~ /^(.+)の(?:画像|写真)(?:(\d+)連発)?\s#/) {
            my $word = url_encode_utf8($1);

            # XXX ここ最悪すぎる直さないとだめ
            my $num = $2 || 0;
            if ($num) {
                $num--;
                if ($num >= 3) {
                    $num = 3;
                }
            }

            my $res  = $furl->get($IMAGE_SEARCH_BASE_URL . qq{?q="$word"&v=1.0});
            unless ($res->is_success) {
                $ur->post(NOT_FOUND_MESSAGE, @tags);
                return;
            }

            my $res_json = decode_json($res->content)->{responseData};

            for my $num (0..$num) {
                if (my $image_url = $res_json->{results}->[$num]->{url}) {
                    my $res = $furl->post(
                        $PYAZO_BASE_URL,
                        ['Content-Type' => 'application/x-www-form-urlencoded'],
                        ['fileurl' => $image_url],
                    );

                    unless ($res->is_success) {
                        $ur->post(ERROR_MESSAGE, @tags);
                        return;
                    }

                    my $pyazo_image_url = $res->{content};
                    if ($pyazo_image_url =~ /\.html$/) {
                        $ur->post('画像じゃないの来た', @tags);
                        return;
                    }

                    $ur->post($pyazo_image_url, @tags);
                }
                else {
                    $ur->post(NOT_FOUND_MESSAGE, @tags);
                    return;
                }
            }
        }
    });
});

$cv->wait;
