//SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "@chainlink/contracts/src/v0.8/ChainlinkClient.sol";

contract FireConsumerMultiNode is ChainlinkClient {
  using Chainlink for Chainlink.Request;

  struct ChainlinkNode {
    address operator_address;
    bytes32 job_id;
  }

  mapping(uint256 => uint256) public fire_data_from_the_last_node;
  uint256[] public all_fire_data;

  mapping(uint256 => uint256[]) public fire_data_list;
  
  uint256 public total_oracle_calls = 0;
  uint256 private node_counter = 0; 
  uint256 public numberOfChainlinkNodes;
  
  uint256[] private index_list;

  uint256[] public numberOfPropertyIdsByOracle;

  mapping(uint256 => uint256[]) public fire_data_grouped_by_property_id;
  mapping(uint256 => uint256) public aggregated_fire_data;
  mapping(uint256 => ChainlinkNode) public chainlink_nodes;

  constructor(uint256 _numberOfChainlinkNodes
  ) {
    numberOfChainlinkNodes = _numberOfChainlinkNodes;
    setChainlinkToken(0xa36085F69e2889c224210F603D836748e7dC0088);
    // setChainlinkOracle(0xf4434feDd55D3d6573627F39fA39867b23f4Bf7F);
    // oracles[0] = 0xA623107254c575105139C499d4869b69582340cB;
    // oracles[1] = 0xf4434feDd55D3d6573627F39fA39867b23f4Bf7F;
    // jobIds[0] = '86d169c2904e487f954807313a20effa';
    // jobIds[1] = 'fd78aec23f7d4995bf0799cdd38e7e6f';
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

  function requestFireData() public {
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
    Chainlink.Request memory req = buildChainlinkRequest(_jobId, address(this), this.fulfillFireData.selector);
    
    req.add("data", "{\"dataset_code\":\"MODIS/006/MOD14A1\", \"selected_band\":\"MaxFRP\", \"image_scale\":1000, \"start_date\":\"2021-09-01\", \"end_date\":\"2021-09-10\", \"geometry\":{\"type\":\"FeatureCollection\",\"features\":[{\"type\":\"Feature\",\"properties\":{\"id\":1},\"geometry\":{\"type\":\"Polygon\",\"coordinates\":[[[29.53125,19.642587534013032],[29.53125,27.059125784374068],[39.90234375,27.059125784374068],[39.90234375,19.642587534013032],[29.53125,19.642587534013032]]]}},{\"type\":\"Feature\",\"properties\":{\"id\":2},\"geometry\":{\"type\":\"Polygon\",\"coordinates\":[[[46.40625,13.752724664396988],[46.40625,20.138470312451155],[56.25,20.138470312451155],[56.25,13.752724664396988],[46.40625,13.752724664396988]]]}}]}}");
       
    sendOperatorRequest(req, payment);
  }

  function fulfillFireData(
    bytes32 requestId,
    uint256[] memory fireData,
    string calldata cidValue
  )
    public
    recordChainlinkFulfillment(requestId)
  {

    
    for (uint256 i = 0; i < fireData.length; i++) {
        fire_data_from_the_last_node[i + 1] = fireData[i];
    }

    fire_data_list[total_oracle_calls] = fireData;
    cids_list.push(cidValue);
    
    total_oracle_calls = total_oracle_calls + 1;

    numberOfPropertyIdsByOracle.push(fireData.length);

  }

  function calculatedAggregatedFireData() public {
      if (total_oracle_calls == numberOfChainlinkNodes) {
        groupByPropertyId();
        uint256 maxPropertyId = getLargest(numberOfPropertyIdsByOracle, numberOfPropertyIdsByOracle.length);

        for (uint256 i = 0; i < maxPropertyId; i++) {
            aggregated_fire_data[i + 1] = mode(fire_data_grouped_by_property_id[i + 1], fire_data_grouped_by_property_id[i + 1].length);
        }
      }
      else {
          revert("disabled");
      }
  }


  function groupByPropertyId() private {

        for (uint256 i = 0; i < total_oracle_calls; i++) {
            for (uint256 j = 0; j < numberOfPropertyIdsByOracle[i]; j++) {
                all_fire_data.push(fire_data_list[i][j]);
            }
        }

        uint256 quotient = all_fire_data.length / numberOfPropertyIdsByOracle.length;
        uint256 remainder = all_fire_data.length % numberOfPropertyIdsByOracle.length;

        uint256 n = remainder == 0 ?  quotient : quotient + 1;


        for (uint256 i = 0; i < n; i++) {
            uint256 index = 0;
            for (uint256 j = 0; j < numberOfPropertyIdsByOracle.length; j++) {
                if (index_list.length < all_fire_data.length) {
                    index_list.push(i + index);
                    fire_data_grouped_by_property_id[i + 1].push(all_fire_data[i + index]);
                    index += numberOfPropertyIdsByOracle[j];
                }
                else {
                    break;
                }
            }
    
        }
    }

   function mode(uint256[] memory array, uint256 length) internal pure returns(uint256) {
        uint256 max = getLargest(array, length);

        uint256[] memory count = new uint256[](max + 1);

        for (uint256 i = 0; i < length; i++) {
            count[array[i]] += 1;
        }

        uint256 modeValue;
        uint256 k = count[0];

        for (uint256 i = 1; i < count.length; i++) {
            if (count[i] > k) {
                k = count[i];
                modeValue = i;
            }
        }      

        return modeValue;
    }
    

    function getLargest(uint256[] memory array, uint256 length) private pure returns(uint256) {
       
       uint256 max = 0;
        
       for (uint256 i = 0; i < length; i++) {
           if (max < array[i]) {
               max = array[i];
           }
       }
       return max;
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