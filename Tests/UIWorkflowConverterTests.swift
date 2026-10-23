import Foundation
import XCTest
@testable import ComfyWorkbenchCore

final class UIWorkflowConverterTests: XCTestCase {
    private func convert(_ graph: String, _ info: String) throws -> JSONValue {
        try JSONValue(data: UIWorkflowConverter.convert(data: Data(graph.utf8), objectInfoData: Data(info.utf8)))
    }

    func testStandardSavedWorkflowKeepsNestedConnections() throws {
        let graph = #"""
        {"nodes":[
          {"id":1,"type":"LoadImage","widgets_values":["demo.png","image"],"outputs":[{"type":"IMAGE"}]},
          {"id":2,"type":"SaveImage","widgets_values":["result"],"inputs":[{"name":"images","link":1}],"outputs":[]}
        ],"links":[[1,1,0,2,0,"IMAGE"]]}
        """#
        let info = #"""
        {"LoadImage":{"input":{"required":{"image":[["demo.png"]]}}},
         "SaveImage":{"output_node":true,"input":{"required":{"images":["IMAGE"],"filename_prefix":["STRING"]}}}}
        """#
        let result = try convert(graph, info)
        XCTAssertEqual(result["1"]?["inputs"]?["image"], .string("demo.png"))
        XCTAssertEqual(result["2"]?["inputs"]?["images"], .array([.string("1"), .integer(0)]))
        XCTAssertEqual(result["2"]?["inputs"]?["filename_prefix"], .string("result"))
    }

    func testStandardLayoutMismatchDoesNotGuess() {
        let info = #"{"SaveImage":{"output_node":true,"input":{"required":{"filename_prefix":["STRING"]}}}}"#
        XCTAssertThrowsError(try convert(#"{"nodes":[{"id":1,"type":"SaveImage","widgets_values":["result","extra"],"outputs":[]}],"links":[]}"#, info))
    }

    func testNamedWidgetsGetSetRerouteAndBypassKeepOnlyOutputAncestors() throws {
        let graph = #"""
        {"nodes":[
          {"id":1,"type":"Loader","widgets_values_named":{"name":"model.safetensors"},"inputs":[],"outputs":[{"type":"MODEL"}]},
          {"id":2,"type":"SetNode","widgets_values_named":{"Constant":"模型"},"inputs":[{"name":"MODEL","type":"MODEL","link":1}],"outputs":[{"type":"MODEL"}]},
          {"id":3,"type":"GetNode","widgets_values_named":{"Constant":"模型"},"inputs":[],"outputs":[{"type":"MODEL"}]},
          {"id":4,"type":"LoraLoaderModelOnly","mode":4,"widgets_values_named":{"lora_name":"disabled.safetensors"},"inputs":[{"name":"model","type":"MODEL","link":2}],"outputs":[{"type":"MODEL"}]},
          {"id":5,"type":"Reroute","inputs":[{"name":"","type":"*","link":3}],"outputs":[{"type":"MODEL"}]},
          {"id":6,"type":"Save","title":"Custom title","widgets_values_named":{"seed":18446744073709551615,"control_after_generate":"randomize"},"inputs":[{"name":"model","type":"MODEL","link":4}],"outputs":[]},
          {"id":7,"type":"Note","widgets_values_named":{"text":"Decoration"},"outputs":[]},
          {"id":8,"type":"Loader","widgets_values_named":{"name":"unused"},"inputs":[],"outputs":[{"type":"MODEL"}]}
        ],"links":[[1,1,0,2,0,"MODEL"],[2,3,0,4,0,"MODEL"],[3,4,0,5,0,"MODEL"],[4,5,0,6,0,"MODEL"]]}
        """#
        let info = #"""
        {"Loader":{"input":{"required":{"name":["STRING"]}}},
         "Save":{"output_node":true,"input":{"required":{"model":["MODEL"],"seed":["INT"]}}}}
        """#
        let result = try convert(graph, info)
        XCTAssertEqual(Set(result.objectValue?.keys.map { $0 } ?? []), Set(["1", "6"]))
        XCTAssertEqual(result["6"]?["inputs"]?["model"], .array([.string("1"), .integer(0)]))
        XCTAssertEqual(result["6"]?["inputs"]?["seed"]?.uint64Value, UInt64.max)
        XCTAssertNil(result["6"]?["inputs"]?["control_after_generate"])
        XCTAssertNil(result["6"]?["_meta"])
    }

    func testDynamicDottedFieldsAndDisabledOptionalReference() throws {
        let graph = #"""
        {"nodes":[
          {"id":1,"type":"LoadImage","mode":4,"widgets_values_named":{"image":"None"},"inputs":[],"outputs":[{"type":"IMAGE"}]},
          {"id":2,"type":"Save","widgets_values_named":{"selection":"sol-attn","selection.tau":1.3,"values.a":10},"inputs":[{"name":"ref_images.ref_image_0","type":"IMAGE","link":1}],"outputs":[]}
        ],"links":[[1,1,0,2,0,"IMAGE"]]}
        """#
        let info = #"""
        {"Save":{"output_node":true,"input":{"required":{
          "selection":["COMFY_DYNAMICCOMBO_V3",{"options":[{"key":"sol-attn","inputs":{"required":{"tau":["FLOAT"]}}}]}],
          "values":["COMFY_AUTOGROW_V3",{"template":{"names":["a","b"],"min":1,"input":{"required":{"value":["FLOAT,INT,BOOLEAN"]}}}}]
        },"optional":{"ref_images":["COMFY_AUTOGROW_V3",{"template":{"prefix":"ref_image_","min":0,"max":9,"input":{"required":{"ref_image":["IMAGE"]}}}}]}}}}
        """#
        let result = try convert(graph, info)
        XCTAssertEqual(result["2"]?["inputs"]?["selection.tau"], .decimal(1.3))
        XCTAssertEqual(result["2"]?["inputs"]?["values.a"], .integer(10))
        XCTAssertNil(result["2"]?["inputs"]?["ref_images.ref_image_0"])
        XCTAssertNil(result["1"])
    }

    func testVHSFormatWidgetsComeFromServerMetadata() throws {
        let result = try convert(#"""
        {"nodes":[{"id":1,"type":"VHS_VideoCombine","widgets_values_named":{"format":"video/h264-mp4","crf":19,"pix_fmt":"yuv420p","videopreview":{"old":"result"}},"inputs":[],"outputs":[]}],"links":[]}
        """#, #"""
        {"VHS_VideoCombine":{"output_node":true,"input":{"required":{"format":[["video/h264-mp4"],{"formats":{"video/h264-mp4":[["crf","INT",{"default":19}],["pix_fmt",["yuv420p"],{}]]}}]}}}}
        """#)
        XCTAssertEqual(result["1"]?["inputs"]?["crf"], .integer(19))
        XCTAssertNil(result["1"]?["inputs"]?["videopreview"])
    }

    func testRejectsPositionalAndUnknownParametersInsteadOfGuessing() {
        let info = #"{"Save":{"output_node":true,"input":{"required":{"value":["INT"]}}}}"#
        XCTAssertThrowsError(try convert(#"{"nodes":[{"id":1,"type":"Save","widgets_values":[9],"outputs":[]}],"links":[]}"#, info))
        XCTAssertThrowsError(try convert(#"{"nodes":[{"id":1,"type":"Save","widgets_values_named":{"value":9,"unknown":4},"outputs":[]}],"links":[]}"#, info))
    }

    func testRejectsAmbiguousBypassAndMissingRequiredSource() {
        let graph = #"""
        {"nodes":[
          {"id":1,"type":"Loader","inputs":[],"outputs":[{"type":"MODEL"}]},
          {"id":2,"type":"Loader","inputs":[],"outputs":[{"type":"MODEL"}]},
          {"id":3,"type":"Merge","mode":4,"inputs":[{"name":"a","type":"MODEL","link":1},{"name":"b","type":"MODEL","link":2}],"outputs":[{"type":"MODEL"}]},
          {"id":4,"type":"Save","inputs":[{"name":"model","type":"MODEL","link":3}],"outputs":[]}
        ],"links":[[1,1,0,3,0,"MODEL"],[2,2,0,3,1,"MODEL"],[3,3,0,4,0,"MODEL"]]}
        """#
        let info = #"{"Loader":{"input":{}},"Save":{"output_node":true,"input":{"required":{"model":["MODEL"]}}}}"#
        XCTAssertThrowsError(try convert(graph, info))
        XCTAssertThrowsError(try convert(#"{"nodes":[{"id":4,"type":"Save","inputs":[],"outputs":[]}],"links":[]}"#, info))
    }
}
