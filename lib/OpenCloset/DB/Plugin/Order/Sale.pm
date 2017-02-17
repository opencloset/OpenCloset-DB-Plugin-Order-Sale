use utf8;

package OpenCloset::DB::Plugin::Order::Sale;

# ABSTRACT: OpenCloset::DB::Plugin::Order::Sale

use strict;
use warnings;

our $VERSION = '0.002';

package
    OpenCloset::Schema::Result::Order; # to prevent module indexing

use strict;
use warnings;

use DateTime;
use List::MoreUtils;

use OpenCloset::Constants::Status;

=method sale_multi_times_rental

    my $sale_price = $order->sale_multi_times_rental( \@order_details );
    my $sale_price = $order->sale_multi_times_rental( \@order_details, DateTime->now );
    my $sale_price = $order->sale_multi_times_rental( \@order_details, $order->create_date );

L<GH #790|https://github.com/opencloset/opencloset/issues/790> 3회째 대여자 부터 대여자의 부담을 줄이기 위해 비용을 할인함

A set of example codes are below:

    my @order_details = (
        {
            clothes_code     => "0J1TS",
            clothes_category => "jacket",
            status_id        => 19,
            name             => "J1TS - 재킷",
            price            => 10000,
            final_price      => 10000,
        },
        ...
    );
    my $sale_price = {
        before                => 0,
        after                 => 0,
        rented_without_coupon => 0,
    };
    if ( $self->config->{sale}{enable} ) {
        $sale_price = $order->sale_multi_times_rental( \@order_details );
        warn(
            sprintf(
                "order %d: %d rented without coupon\n",
                $order->id,
                $sale_price->{rented_without_coupon},
            )
        );
    }
    for my $order_detail (@order_details) {
        $order->add_to_order_details(
            {
                clothes_code => $order_detail->{clothes_code},
                status_id    => $order_detail->{status_id},
                name         => $order_detail->{name},
                price        => $order_detail->{price},
                final_price  => $order_detail->{final_price},
                desc         => $order_detail->{desc},
            }
        ) or die "failed to create a new order_detail\n";
    }
    if ( $sale_price->{before} != $sale_price->{after} ) {
        my $sale = $self->DB->resultset("Sale")->find( { name => "3times" } );
        my $clothes_tag = $self->DB->resultset("OrderSale")->create(
            {
                order_id => $order->id,
                sale_id  => $sale->id,
            }
        );

        my $desc = sprintf(
            "기존 대여료: %s원, 할인 금액 %s원",
            $self->commify( $sale_price->{before} ),
            $self->commify( $sale_price->{before} - $sale_price->{after} ),
        );
    }

=cut

sub sale_multi_times_rental {
    my ( $self, $order_details, $dt ) = @_;

    $dt ||= DateTime->now;

    my %sale_price = (
        before                => 0,
        after                 => 0,
        rented_without_coupon => 0,
    );
    for my $order_detail (@$order_details) {
        $sale_price{before} += $order_detail->{final_price};
        $sale_price{after}  += $order_detail->{final_price};
    }

    #
    # 쿠폰을 제외하고 몇 회째 대여인가?
    #
    my $rented_without_coupon = 0;
    {
        my $orders = $self->user->orders;
        my $dtf    = $self->result_source->schema->storage->datetime_parser;
        my $rented_without_coupon_order_rs = $orders->search(
            {
                status_id   => $OpenCloset::Constants::Status::RETURNED,
                parent_id   => undef,
                return_date => { "<" => $dtf->format_datetime($dt) },
                -and        => [
                    -or => [
                        {
                            "coupon.id"     => { "!=" => undef },
                            "coupon.status" => { "!=" => "used" },
                        },
                        {
                            "coupon.id" => undef,
                        },
                    ],
                ],
            },
            {
                join => [qw/ coupon /],
            },
        );

        $sale_price{rented_without_coupon} = $rented_without_coupon_order_rs->count;
    }

    #
    # 3회 째 방문이라면 조건 충족
    #
    return \%sale_price unless $sale_price{rented_without_coupon} >= 2;

    my %order_details_by_category = (
        "shirt-blouse" => [],
        "pants-skirt"  => [],
        "jacket"       => [],
        "tie"          => [],
        "shoes"        => [],
        "belt"         => [],
        "etc"          => [],
    );
    my %count_by_category = (
        "shirt-blouse" => 0,
        "pants-skirt"  => 0,
        "jacket"       => 0,
        "tie"          => 0,
        "shoes"        => 0,
        "belt"         => 0,
        "etc"          => 0,
    );
    my $jacket      = 0;
    my $pants_skirt = 0;
    for my $order_detail (@$order_details) {
        my $category = $order_detail->{clothes_category};

        use experimental qw( switch );
        given ($category) {
            when (/^shirt|blouse$/) {
                my $adjust_category = "shirt-blouse";
                push @{ $order_details_by_category{$adjust_category} }, $order_detail;
                ++$count_by_category{$adjust_category};
            }
            when (/^pants|skirt$/) {
                my $adjust_category = "pants-skirt";
                push @{ $order_details_by_category{$adjust_category} }, $order_detail;
                ++$count_by_category{$adjust_category};
            }
            when (/^jacket|tie|shoes|belt$/) {
                push @{ $order_details_by_category{$category} }, $order_detail;
                ++$count_by_category{$category};
            }
            default {
                my $adjust_category = "etc";
                push @{ $order_details_by_category{$adjust_category} }, $order_detail;
                ++$count_by_category{$adjust_category};
            }
        }
    }

    #
    # 재킷 또는 바지, 치마가 각각 3개 미만이어야 조건 충족
    #
    return \%sale_price
        unless $count_by_category{"jacket"} < 3 && $count_by_category{"pants-skirt"} < 3;

    my $ea = List::MoreUtils::each_arrayref(
        $order_details_by_category{"shirt-blouse"},
        $order_details_by_category{"pants-skirt"},
        $order_details_by_category{"jacket"},
        $order_details_by_category{"tie"},
        $order_details_by_category{"shoes"},
        $order_details_by_category{"belt"},
    );
    while ( my ( $shirt_blouse, $pants_skirt, $jacket, $tie, $shoes, $belt ) = $ea->() )
    {
        if ( $jacket && $pants_skirt ) {
            if ($tie) {
                $sale_price{after} -= $tie->{price} - 0;

                $tie->{price}       = 0;
                $tie->{final_price} = 0;

                if ( $shirt_blouse || $shoes || $belt ) {
                    #
                    # 위 아래 셋트와 타이가 있으며 다른 항목이 있으므로 셋트 가격만 지불
                    #
                    for my $order_detail ( $shirt_blouse, $shoes, $belt ) {
                        next unless $order_detail;

                        $sale_price{after} -= $order_detail->{price} - 0;

                        $order_detail->{price}       = 0;
                        $order_detail->{final_price} = 0;
                        $order_detail->{desc}        = "3회 이상 방문(셋트 이외 무료)";
                    }
                }
                else {
                    #
                    # 위 아래 셋트와 타이가 있으며 다른 항목이 없으므로 30% 할인
                    #
                    for my $order_detail ( $jacket, $pants_skirt, $tie ) {
                        next unless $order_detail;

                        $sale_price{after} -= $order_detail->{price} * 0.3;

                        $order_detail->{price}       *= 0.7;
                        $order_detail->{final_price} *= 0.7;
                        $order_detail->{desc} = "3회 이상 방문(30% 할인)";
                    }
                }
            }
            else {
                if ( $shirt_blouse || $shoes || $belt ) {
                    #
                    # 위 아래 셋트이며 다른 항목이 있으므로 셋트 가격만 지불
                    #
                    for my $order_detail ( $shirt_blouse, $shoes, $belt ) {
                        next unless $order_detail;

                        $sale_price{after} -= $order_detail->{price} - 0;

                        $order_detail->{price}       = 0;
                        $order_detail->{final_price} = 0;
                        $order_detail->{desc}        = "3회 이상 방문(셋트 이외 무료)";
                    }
                }
                else {
                    #
                    # 위 아래 셋트이며 다른 항목이 없으므로 30% 할인
                    #
                    for my $order_detail ( $jacket, $pants_skirt ) {
                        next unless $order_detail;

                        $sale_price{after} -= $order_detail->{price} * 0.3;

                        $order_detail->{price}       *= 0.7;
                        $order_detail->{final_price} *= 0.7;
                        $order_detail->{desc} = "3회 이상 방문(30% 할인)";
                    }
                }
            }
        }
        else {
            #
            # 위 아래 셋트가 아니므로 일괄 30% 할인
            #
            if ($tie) {
                $tie->{price}       = 2000;
                $tie->{final_price} = 2000;
            }
            for my $order_detail ( $shirt_blouse, $pants_skirt, $jacket, $tie, $shoes, $belt ) {
                next unless $order_detail;

                $sale_price{after} -= $order_detail->{price} * 0.3;

                $order_detail->{price}       *= 0.7;
                $order_detail->{final_price} *= 0.7;
                $order_detail->{desc} = "3회 이상 방문(30% 할인)";
            }
        }
    }

    #
    # 이외의 항목은 일괄 30% 할인
    #
    for my $order_detail ( @{ $order_details_by_category{etc} } ) {
        $sale_price{after} -= $order_detail->{price} * 0.3;

        $order_detail->{price}       *= 0.7;
        $order_detail->{final_price} *= 0.7;
        $order_detail->{desc} = "3회 이상 방문(30% 할인)";
    }

    return \%sale_price;
}

1;

# COPYRIGHT

__END__

=for Pod::Coverage

=head1 SYNOPSIS

    use OpenCloset::DB::Plugin::Order::Sale;

    ...

=head1 DESCRIPTION

...


=head1 INSTALLATION

L<OpenCloset::DB::Plugin::Order::Sale> uses well-tested and widely-used CPAN modules, so installation should be as simple as

    $ cpanm --mirror=https://cpan.theopencloset.net --mirror=http://cpan.silex.kr --mirror-only OpenCloset::DB::Plugin::Order::Sale

when using L<App::cpanminus>. Of course you can use your favorite CPAN client or install manually by cloning the L</"Source Code">.
