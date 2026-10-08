let module = import (args[0]);
let mode = args[1];
let fail = () -> 1 / 0;
if mode == "native" {
  module.fail();
} else if mode == "callback" {
  module.apply(fail);
} else if mode == "reused" {
  module.reuse();
} else if mode == "after" {
  module.apply(() -> 1); 1 / 0;
};
