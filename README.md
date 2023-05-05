### Banawá SSH library.

[awa-ssh](http://www.github.com/haesbaert/awa-ssh) is an
_ISC-licensed_ SSH library implementation in ocaml.
[banawa-ssh](https://github.com/sorbusursina/banawa-ssh) is a fork of awa-ssh.

Like awa-ssh, the main goal is to provide a purely functional SSH
implementation for embedding in unikernels. This will allow us to have control
SSH interfaces in [mirage](https://mirage.io). Banawa comes with an
authentication flow more suitable to TOFU (trust on first use). That is, when a
client attempts authenticating with a ssh key and the user does not exist the
user is created with the provided public key.

This is also a work in progress software. Changes may be upstreamed to awa-ssh
to allow for TOFU-servers. This fork is not expected to be maintained in the
longer term. Please reach out if you would like to use something like this.

The name `awá` is a reference to the critically endangered indigenous people of
Brazil.

[Awá@survivalinternational](http://www.survivalinternational.org/awa)

[Awá@wikipedia](https://en.wikipedia.org/wiki/Awá-Guajá_people)

The name `banawá` is a reference to another indigenous people of Brazil.

[Banawá@wikipedia](https://en.wikipedia.org/wiki/Banaw%C3%A1)
