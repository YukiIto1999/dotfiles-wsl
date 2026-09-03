{ username }:
path: content: {
  inherit path content;
  mode = "0600";
  owner = username;
  group = "users";
}
