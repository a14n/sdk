// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

#ifndef BIN_RESOURCES_H_
#define BIN_RESOURCES_H_

#include <stddef.h>
#include <string.h>

// Map from Blink to Dart VM.
#if defined(_DEBUG)
#define DEBUG
#endif

#include "platform/assert.h"


namespace dart {
namespace bin {

class Resources {
 public:
  static const int kNoSuchInstance = -1;

  static int ResourceLookup(const char* path, const char** resource) {
    for (int i = 0; i < get_resource_count(); i++) {
      resource_map_entry* entry = get_resource(i);
      if (strcmp(path, entry->path_) == 0) {
        *resource = entry->resource_;
        ASSERT(entry->length_ > 0);
        return entry->length_;
      }
    }
    return kNoSuchInstance;
  }

  static intptr_t get_resource_count() {
    return builtin_resources_count_;
  }

  static const char* get_resource_path(intptr_t i) {
    return get_resource(i)->path_;
  }

 private:
  struct resource_map_entry {
    const char* path_;
    const char* resource_;
    intptr_t length_;
  };

  // These fields are generated by resources_gen.cc.
  static resource_map_entry builtin_resources_[];
  static const intptr_t builtin_resources_count_;

  static resource_map_entry* get_resource(int i) {
    ASSERT(i >= 0 && i < builtin_resources_count_);
    return &builtin_resources_[i];
  }

  DISALLOW_ALLOCATION();
  DISALLOW_IMPLICIT_CONSTRUCTORS(Resources);
};

}  // namespace bin
}  // namespace dart

#endif  // BIN_RESOURCES_H_
