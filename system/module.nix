{ config, ... }:

{
  # Home Manager の activation は複数 unit の資材を配備する横断の入口
  my.doctor.units."home-manager-${config.my.username}.service".expected = {
    LoadState = "loaded";
    ActiveState = "active";
    SubState = "exited";
    Result = "success";
  };
}
