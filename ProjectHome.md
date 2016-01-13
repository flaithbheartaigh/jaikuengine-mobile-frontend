This is the frontend that lets the JaikuEngine mobile client talk to the JaikuEngine.

For setup instructions see http://docs.google.com/View?id=d2z73bg_43fjmnt5qn

You'll also need to tweak the djabberd.conf to talk to your instance.

Note that the frontend needs root keys to JaikuEngine - you won't be able to set up one on your own to talk to jaiku.com. To lift this restriction we need to decide whether the conversion of the XMPP-style login to a oauth keypair can be made generally available.