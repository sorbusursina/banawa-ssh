let b64s x = Cstruct.to_string x |> Base64.encode_string

let () =
  match Banawa.Keys.of_string Sys.argv.(1) with
  | Ok pk ->
    let pub = Banawa.Hostkey.pub_of_priv pk in
    let public = Banawa.Wire.blob_of_pubkey pub in
    Format.printf "%s %s awa@awa.local\n%!"
      (Banawa.Hostkey.sshname pub)
      (b64s public)
  | Error (`Msg err) ->
    Format.eprintf "%s: %s.\n%!" Sys.argv.(0) err ;
    exit 1
