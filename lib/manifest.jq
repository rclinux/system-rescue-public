# Validation shared by verification and restore. v3 lacks occupancy fields.
def positive_integer: type == "number" and . > 0 and floor == .;
def filename: type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_.-]*$");
def checksum: type == "string" and test("^[a-f0-9]{64}$");
def optional_count: . == null or (type == "number" and . >= 0 and floor == .);

# Invoked with --slurp to reject concatenated JSON documents.
if length != 1 then error("expected one manifest") else .[0] end |
type == "object" and
(.system_rescue_manifest_version == 3 or .system_rescue_manifest_version == 4) and
(.source_disk.size_bytes | positive_integer) and
(.partition_table.type == "gpt" or .partition_table.type == "dos") and
(.partition_table.dump_file | filename) and
(.partitions | type == "array" and length > 0) and
(.source_disk.size_bytes as $capacity |
 all(.partitions[];
     (.number | positive_integer) and
     (.size_bytes | positive_integer) and .size_bytes <= $capacity and
     (.fstype | type == "string") and
     (.uuid | type == "string") and
     (.label | type == "string") and
     (.fs_used_bytes | optional_count) and
     (.fs_inodes_used | optional_count) and
     (if .restore_method == "mkswap" then
          .fstype == "swap" and (.uuid | length > 0) and
          .image_file == "" and .checksum_sha256 == ""
      else
          (.restore_method == "partclone" or .restore_method == "rawdd") and
          (.image_file | filename) and (.checksum_sha256 | checksum)
      end))) and
([.partitions[].number] | length == (unique | length)) and
([.partitions[] | select(.restore_method != "mkswap") | .image_file] |
 length > 0 and length == (unique | length)) and
(.partition_table.dump_file as $table | all(.partitions[]; .image_file != $table))
