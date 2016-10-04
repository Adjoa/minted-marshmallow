# Submitted by: Adjoa Darien
# Last updated: Oct-04-2016
# Defines a virtual host
class profile::apache {
  # default_vhost setting allows for the creation of customized Apache virtual hosts
  # log_formats setting instructs the web server to log the ip address of the requesting
  # client (instead of the proxy's ip address) which is being passed to it from the HTTP
  # header field %{X-Forwarded-For}i
  class { 'apache':
    default_vhost => false,
  }
  
  # Configures a name-based virtual host with the hostname first.example.com and,
  # instructs the server not to log requests for the file check.txt
  apache::vhost { 'first.example.com':
    port               => $apache_port,
    docroot            => "${::apache::params::docroot}/first.example.com",
  }

  file {"${::apache::params::docroot}/first.example.com/default.html":
    ensure  => present,
    source  => "puppet:///modules/profile/default.html",
    require => Apache::Vhost['first.example.com'],
  }
}
