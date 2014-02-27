#!/usr/bin/env perl

use strict;
use warnings;
use utf8;
use AnyEvent;
use Furl;
use FindBin;
use JSON qw/decode_json/;
use Redis::Fast;
use Unruly;
use URL::Encode qw/url_encode_utf8/;
use WebService::ImKayac::Simple;

use constant {
    NOT_FOUND_MESSAGE => '画像無かったっぽい',
    ERROR_MESSAGE     => 'なんか調子悪いみたい',
    EXPIRE_TIME       => 60 * 60 * 24 * 3, # 3日間
};

my $ERROR_COUNT = 0;

my $conf = do "$FindBin::Bin/../config.pl";
my $YANCHA_URL            = $conf->{YANCHA_URL};
my $PYAZO_BASE_URL        = $conf->{PYAZO_BASE_URL};
my $IMAGE_SEARCH_BASE_URL = $conf->{IMAGE_SEARCH_BASE_URL};

my $redis = Redis::Fast->new(sock => "$FindBin::Bin/../tmp/redis.sock");
my $furl  = Furl->new(timeout => 10);

my $ur = Unruly->new(
    url  => $YANCHA_URL,
    tags => {PUBLIC => 1}
);

$ur->login('fujita', {
    login_point => 'login',
    image => 'http://pyazo.hachiojipm.org/image/ejdnGAqYLbTPOzkI139037834748620.png',
});

my $cv = AnyEvent->condvar;

work($ur);

$cv->wait;

sub work {
    my $ur = shift;
    eval {
        $ur->run(sub {
            my ($client, $socket) = @_;
            $socket->on('user message' => sub {
                my ($socket_info, $message) = @_;

                return if $message->{is_message_log}; # オリジナルPost以外を無視

                my @tags = @{$message->{tags}};
                my $message_text = $message->{text};
                if ($message->{text} =~ /^(.+)の(?:画像|写真)(?:(\d+)連発)?\s#/) {
                    my $word = $1;
                    my $url_encoded_word = url_encode_utf8($word);

                    # XXX ここ最悪すぎる直さないとだめ
                    my $num = $2 || 0;
                    if ($num) {
                        $num--;
                        if ($num >= 3) {
                            $num = 3;
                        }
                    }

                    my $res  = $furl->get($IMAGE_SEARCH_BASE_URL . qq{?q="$url_encoded_word"&v=1.0});
                    unless ($res->is_success) {
                        $ur->post(NOT_FOUND_MESSAGE, @tags);
                        return;
                    }

                    my $res_json = decode_json($res->content)->{responseData};

                    TOP: for my $num (0..$num) {
                        # Redisにキャッシュした内容を引っ張ってくる
                        my $item = $redis->lindex($word, $num);
                        if ($item) {
                            my ($pyazo_image_url, $image_url) = split /,/, $item;
                            $ur->post($pyazo_image_url . "\n" . $image_url, @tags);
                            next TOP;
                        }

                        # Redisにキャッシュ無かったらPyazoにアップする
                        if (my $image_url = $res_json->{results}->[$num]->{url}) {
                            my $res = $furl->post(
                                $PYAZO_BASE_URL . "?auto_resize=1&width=200&height=200", # XXX 決め打ちだけどどうだろうか
                                ['Content-Type' => 'application/x-www-form-urlencoded'],
                                ['fileurl' => $image_url],
                            );

                            unless ($res->is_success) {
                                $ur->post(ERROR_MESSAGE, @tags);
                                next;
                            }

                            my $pyazo_image_url = $res->{content};
                            if ($pyazo_image_url =~ /\.html$/) {
                                $ur->post('画像じゃないの来た', @tags);
                                next;
                            }

                            $ur->post("$pyazo_image_url\n$image_url", @tags);

                            # RedisにPyazo URLとOriginal URLをキャッシュ
                            if ($redis->llen($word) < 4) {
                                my $hit = 0;
                                for my $i (0..3) {
                                    my $item = $redis->lindex($word, $i);

                                    last unless ($item);
                                    if ($item eq $pyazo_image_url) {
                                        $hit = 1;
                                        last;
                                    }
                                }

                                unless ($hit) {
                                    $redis->rpush($word => "$pyazo_image_url,$image_url");
                                    $redis->expire($word, EXPIRE_TIME);
                                }
                            }
                        }
                        else {
                            $ur->post(NOT_FOUND_MESSAGE, @tags);
                            return;
                        }
                    }
                }
            });
        });
    };

    if ($@) {
        if (++$ERROR_COUNT > 10) {
            my $imkayac_conf = do "$FindBin::Bin/../imkayac_config.pl";
            my $im = WebService::ImKayac::Simple->new(
                type     => 'password',
                user     => $imkayac_conf->{USER_NAME},
                password => $imkayac_conf->{PASSWORD},
            );
            $im->send('[WARN] Fujita has gone!!');
            die;
        }

        sleep(10);

        work($ur);
    }
}
