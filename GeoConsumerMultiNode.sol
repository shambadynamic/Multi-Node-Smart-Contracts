//SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "@chainlink/contracts/src/v0.8/ChainlinkClient.sol";

contract GeoConsumerMultiNode is ChainlinkClient {
  using Chainlink for Chainlink.Request;

  struct ChainlinkNode {
    address operator_address;
    bytes32 job_id;
  }

  int256[] public geospatial_data_list;
  uint256 public total_oracle_calls = 0;
  uint256 private node_counter = 0; 
  uint256 public numberOfChainlinkNodes;

  int256 public aggregated_geospatial_data;
  mapping(uint256 => ChainlinkNode) public chainlink_nodes;

  constructor(uint256 _numberOfChainlinkNodes
  ) {
    numberOfChainlinkNodes = _numberOfChainlinkNodes;
    setChainlinkToken(0xa36085F69e2889c224210F603D836748e7dC0088);
    // setChainlinkOracle(0xf4434feDd55D3d6573627F39fA39867b23f4Bf7F);
    // oracles[0] = 0xA623107254c575105139C499d4869b69582340cB;
    // oracles[1] = 0xf4434feDd55D3d6573627F39fA39867b23f4Bf7F;
    // jobIds[0] = 'a8c9590bae904f328eb155f10d4ac841';
    // jobIds[1] = '83191779e6c74593b7a99bea8c116e31';
  }



  string[] public cids_list;

  function getCid(uint256 index)
        public
        view
        returns (string memory)
  {
        return cids_list[index];
  }

  function setChainlinkNodes(address _operatorAddress, string memory _jobId) public {
       

        ChainlinkNode memory chainlink_node = ChainlinkNode({
            job_id: stringToBytes32(_jobId),
            operator_address: _operatorAddress
        });

        chainlink_nodes[node_counter] = chainlink_node;
        node_counter += 1;
       
  }

  function requestGeospatialData() public {
       for (uint256 i = 0; i < numberOfChainlinkNodes; i++) {
           sendRequestToOracle(chainlink_nodes[i].operator_address, chainlink_nodes[i].job_id);
       } 
  }

  function sendRequestToOracle(address _oracle, bytes32 _jobId
  )
    private
  {
    setChainlinkOracle(_oracle);
    uint256 payment = 0.1 * 10**19; //1000000000000000000;
    Chainlink.Request memory req = buildChainlinkRequest(_jobId, address(this), this.fulfillGeospatialData.selector);
    
    req.add("data", "{\"agg_x\": \"agg_mean\", \"dataset_code\":\"COPERNICUS/S2_SR\", \"selected_band\":\"NDVI\", \"image_scale\":250.0, \"start_date\":\"2021-09-01\", \"end_date\":\"2021-09-10\", \"geometry\":{\"type\":\"FeatureCollection\",\"features\":[{\"type\":\"Feature\",\"properties\":{\"id\":1},\"geometry\":{\"type\":\"Polygon\",\"coordinates\":[[[19.51171875,4.214943141390651],[18.28125,-4.740675384778361],[26.894531249999996,-4.565473550710278],[27.24609375,1.2303741774326145],[19.51171875,4.214943141390651]]]}}]}}");
        
    sendOperatorRequest(req, payment);
  }

  function fulfillGeospatialData(
    bytes32 requestId,
    int256 geospatialData,
    string calldata cidValue
  )
    public
    recordChainlinkFulfillment(requestId)
  {

    geospatial_data_list.push(geospatialData);
    cids_list.push(cidValue);
    
    total_oracle_calls = total_oracle_calls + 1;

    if (total_oracle_calls == numberOfChainlinkNodes) {
        aggregated_geospatial_data = median(geospatial_data_list, numberOfChainlinkNodes);
    }


  }

   function swap(int256[] memory array, uint256 i, uint256 j) internal pure {
        (array[i], array[j]) = (array[j], array[i]);
    }

    function sort(int256[] memory array, uint256 begin, uint256 end) internal pure {
        if (begin < end) {
            uint256 j = begin;
            int256 pivot = array[j];
            for (uint256 i = begin + 1; i < end; ++i) {
                if (array[i] < pivot) {
                    swap(array, i, ++j);
                }
            }
            swap(array, begin, j);
            sort(array, begin, j);
            sort(array, j + 1, end);
        }
    }
    function median(int256[] memory array, uint256 length) internal pure returns(int256) {
        sort(array, 0, length);
        return length % 2 == 0 ? (array[length/2-1] + array[length/2]) / 2 : array[length/2];
    }

    function stringToBytes32(string memory source) private pure returns (bytes32 result) {
        bytes memory tempEmptyStringTest = bytes(source);
        if (tempEmptyStringTest.length == 0) {
            return 0x0;
        }
        assembly {
            result := mload(add(source, 32))
        }
    }
}