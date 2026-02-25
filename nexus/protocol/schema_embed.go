package protocol

import _ "embed"

//go:embed schema/directivespec_capabilities_net.schema.v1.json
var NetCapabilitySchemaV1 []byte

//go:embed schema/directivespec_capabilities_fs.schema.v1.json
var FsCapabilitySchemaV1 []byte
