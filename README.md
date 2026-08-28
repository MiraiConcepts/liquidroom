# liquidroom

liquidroom is a music decomposition pipeline for stem generation.

# Capabilities

liquidroom turns a track name into a folder of separated stems, published back to
every device that syncs the drop folder.

- A request is an empty folder, created where the finished stems will appear:
  an artist folder holding a track folder. There is no interface and no queue to
  manage, and creating a folder is something every file manager can do.
- The folder itself is the state. Empty means the track is wanted, a note inside
  means it was attempted and did not work, and a full folder means it is done.
  Deleting the note asks again.
- Requested tracks are fetched from a peer-to-peer music network, ranked toward
  what a CD rip looks like — lossless, at CD sample rate, with the artist and
  title in the filename. These are preferences, so a track that exists only as a
  poorer copy still arrives.
- Separation produces a full set of instrument stems, using a model chosen for
  its accuracy on guitar rather than for its speed.
- The guitar stem is split further into lead and rhythm parts. A missing split
  degrades the result rather than failing the run.
- Minus-one mixes are built for each guitar part, so a track can be practised
  with that part removed.
- Published names are made portable before anything is written. Characters that
  Windows rejects are substituted, because a sync client does not translate them
  and a receiving device would strand the folder silently.
- Publication is a single atomic rename, so a syncing peer never observes a
  half-written folder.
- Downloading and processing run in separate containers, and the processing
  container has no network access at all.
- Model files are pinned by checksum and re-verified before every run, because
  fetched once is not the same as correct forever.
