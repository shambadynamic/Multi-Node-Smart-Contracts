// SPDX-License-Identifier: MIT

pragma solidity ^0.8.7;

pragma experimental ABIEncoderV2;

import "@chainlink/contracts/src/v0.8/ChainlinkClient.sol";
import "@chainlink/contracts/src/v0.8/interfaces/LinkTokenInterface.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorInterface.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";


contract InsuranceProvider {
    
    // using SafeMathChainlink for uint;
    address public insurer = msg.sender;
    AggregatorV3Interface internal priceFeed;

    uint public constant DAY_IN_SECONDS = 60; //How many seconds in a day. 60 for testing, 86400 for Production
    
    uint256 constant private ORACLE_PAYMENT = 0.1 * 10**19; // 1 LINK
    address public constant LINK_KOVAN = 0xa36085F69e2889c224210F603D836748e7dC0088 ; //address of LINK token on Kovan
    
    //here is where all the insurance contracts are stored.
    mapping (address => InsuranceContract) contracts; 
    
    
    constructor()   public payable {
        priceFeed = AggregatorV3Interface(0x9326BFA02ADD2366b30bacB125260Af641031331);
    }

    /**
     * @dev Prevents a function being run unless it's called by the Insurance Provider
     */
    modifier onlyOwner() {
		require(insurer == msg.sender,'Only Insurance provider can do this');
        _;
    }
    

   /**
    * @dev Event to log when a contract is created
    */    
    event contractCreated(address _insuranceContract, uint _premium, uint _totalCover);
    
    
    /**
     * @dev Create a new contract for client, automatically approved and deployed to the blockchain
     */ 
    function newContract(address payable _client, uint _duration, uint _premium, uint _payoutValue) public payable onlyOwner() returns(address) {
        

        //create contract, send payout amount so contract is fully funded plus a small buffer
        InsuranceContract i = (new InsuranceContract){value:((_payoutValue * 1 ether) / (uint(getLatestPrice())))}(_client, _duration, _premium, _payoutValue, LINK_KOVAN,ORACLE_PAYMENT);
         
        contracts[address(i)] = i;  //store insurance contract in contracts Map
        
        //emit an event to say the contract has been created and funded
        emit contractCreated(address(i), msg.value, _payoutValue);
        
        //now that contract has been created, we need to fund it with enough LINK tokens to fulfil 1 Oracle request per day, with a small buffer added
        LinkTokenInterface link = LinkTokenInterface(i.getChainlinkToken());
        link.transfer(address(i), ((_duration / DAY_IN_SECONDS) + 2) * ORACLE_PAYMENT * 2);
        
        
        return address(i);
        
    }
    

    /**
     * @dev returns the contract for a given address
     */
    function getContract(address _contract) external view returns (InsuranceContract) {
        return contracts[_contract];
    }
    
    /**
     * @dev updates the contract for a given address
     */
    function updateContract(address _contract) external {
        InsuranceContract i = InsuranceContract(_contract);
        i.updateContract();
    }
    
    /**
     * @dev gets the current rainfall for a given contract address
     */
    function getContractRainfall(address _contract) external view returns(int) {
        InsuranceContract i = InsuranceContract(_contract);
        return i.getCurrentRainfall();
    }
    
    /**
     * @dev gets the current rainfall for a given contract address
     */
    function getContractRequestCount(address _contract) external view returns(uint) {
        InsuranceContract i = InsuranceContract(_contract);
        return i.getRequestCount();
    }
    
    
    
    /**
     * @dev Get the insurer address for this insurance provider
     */
    function getInsurer() external view returns (address) {
        return insurer;
    }
    
    
    
    /**
     * @dev Get the status of a given Contract
     */
    function getContractStatus(address _address) external view returns (bool) {
        InsuranceContract i = InsuranceContract(_address);
        return i.getContractStatus();
    }
    
    /**
     * @dev Return how much ether is in this master contract
     */
    function getContractBalance() external view returns (uint) {
        return address(this).balance;
    }
    
    /**
     * @dev Function to end provider contract, in case of bugs or needing to update logic etc, funds are returned to insurance provider, including any remaining LINK tokens
     */
    function endContractProvider() external payable onlyOwner() {
        LinkTokenInterface link = LinkTokenInterface(LINK_KOVAN);
        require(link.transfer(msg.sender, link.balanceOf(address(this))), "Unable to transfer");
        selfdestruct(payable(insurer));
    }
    
    /**
     * Returns the latest price
     */
    function getLatestPrice() public view returns (int) {
        (
            uint80 roundID, 
            int price,
            uint startedAt,
            uint timeStamp,
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();
        // If the round is not complete yet, timestamp is 0
        require(timeStamp > 0, "Round not complete");
        return price;
    }
    
    /**
     * @dev fallback function, to receive ether
     */
    //function() external payable {  }

}

contract InsuranceContract is ChainlinkClient  {
    using Chainlink for Chainlink.Request;

    AggregatorV3Interface internal priceFeed;
    
    uint public constant DAY_IN_SECONDS = 60; //How many seconds in a day. 60 for testing, 86400 for Production
    uint public constant DROUGHT_DAYS_THRESDHOLD = 3 ;  //Number of consecutive days without rainfall to be defined as a drought
    uint256 private oraclePaymentAmount;

    address payable public insurer;
    address payable client;
    uint startDate;
    uint duration;
    uint premium;
    uint payoutValue;
    // string cropLocation;
    string public cid;
    uint256 public total_oracle_calls = 0;
    

    int256[2] public currentRainfallList;
    bytes32[2] public jobIds;
    address[2] public oracles;
    
    
    uint daysWithoutRain;                   //how many days there has been with 0 rain
    bool contractActive;                    //is the contract currently active, or has it ended
    bool contractPaid = false;
    int currentRainfall = 0;               //what is the current rainfall for the location
    uint currentRainfallDateChecked = block.timestamp;  //when the last rainfall check was performed
    uint requestCount = 0;                  //how many requests for rainfall data have been made so far for this insurance contract
    uint dataRequestsSent = 0;             //variable used to determine if both requests have been sent or not
    

    /**
     * @dev Prevents a function being run unless it's called by Insurance Provider
     */
    modifier onlyOwner() {
		require(insurer == msg.sender,'Only Insurance provider can do this');
        _;
    }
    
    /**
     * @dev Prevents a function being run unless the Insurance Contract duration has been reached
     */
    modifier onContractEnded() {
        if (startDate + duration < block.timestamp) {
          _;  
        } 
    }
    
    /**
     * @dev Prevents a function being run unless contract is still active
     */
    modifier onContractActive() {
        require(contractActive == true ,'Contract has ended, cant interact with it anymore');
        _;
    }

    /**
     * @dev Prevents a data request to be called unless it's been a day since the last call (to avoid spamming and spoofing results)
     * apply a tolerance of 2/24 of a day or 2 hours.
     */    
    modifier callFrequencyOncePerDay() {
        require((block.timestamp - currentRainfallDateChecked) > (DAY_IN_SECONDS - (DAY_IN_SECONDS / 12)),'Can only check rainfall once per day');
        _;
    }
    
    event contractCreated(address _insurer, address _client, uint _duration, uint _premium, uint _totalCover);
    event contractPaidOut(uint _paidTime, uint _totalPaid, int _finalRainfall);
    event contractEnded(uint _endTime, uint _totalReturned);
    event ranfallThresholdReset(int _rainfall);
    event dataRequestSent(bytes32 requestId);
    event dataReceived(int _rainfall);

    /**
     * @dev Creates a new Insurance contract
     */ 
    constructor(address payable _client, uint _duration, uint _premium, uint _payoutValue, 
                address _link, uint256 _oraclePaymentAmount)  payable public {
        
        //set ETH/USD Price Feed
        priceFeed = AggregatorV3Interface(0x9326BFA02ADD2366b30bacB125260Af641031331);
        
        //initialize variables required for Chainlink Network interaction
        setChainlinkToken(_link);
        // setChainlinkOracle(0xA623107254c575105139C499d4869b69582340cB);
        oraclePaymentAmount = _oraclePaymentAmount;
        
        //first ensure insurer has fully funded the contract
        require(msg.value >= _payoutValue / uint(getLatestPrice()), "Not enough funds sent to contract");
        
        //now initialize values for the contract
        insurer= payable(msg.sender);
        client = _client;
        startDate = block.timestamp; //contract will be effective immediately on creation
        duration = _duration;
        premium = _premium;
        payoutValue = _payoutValue;
        daysWithoutRain = 0;
        contractActive = true;
        

        oracles[0] = 0xA623107254c575105139C499d4869b69582340cB;
        oracles[1] = 0xf4434feDd55D3d6573627F39fA39867b23f4Bf7F;
        jobIds[0] = 'a8c9590bae904f328eb155f10d4ac841';
        jobIds[1] = '83191779e6c74593b7a99bea8c116e31';
        
        emit contractCreated(insurer,
                             client,
                             duration,
                             premium,
                             payoutValue);
    }
    
   /**
     * @dev Calls out to an Oracle to obtain weather data
     */ 
    function updateContract() public onContractActive() returns (bytes32 requestId)   {
        //first call end contract in case of insurance contract duration expiring, if it hasn't then this functin execution will resume
        checkEndContract();
        
        //contract may have been marked inactive above, only do request if needed
        if (contractActive) {
            dataRequestsSent = 0;
        
            checkRainfall(oracles[0], jobIds[0]);

            
            checkRainfall(oracles[1], jobIds[1]);    
        }
    }
    
    /**
     * @dev Calls out to an Oracle to obtain weather data
     */ 
    function checkRainfall(address _oracle, bytes32 _jobId) private onContractActive() returns (bytes32 requestId)   {


        //First build up a request to get the current rainfall

        setChainlinkOracle(_oracle);

        Chainlink.Request memory req = buildChainlinkRequest(_jobId, address(this), this.checkRainfallCallBack.selector);
           
        
        req.add("data", "{\"agg_x\": \"agg_mean\", \"dataset_code\":\"COPERNICUS/S2_SR\", \"selected_band\":\"NDVI\", \"image_scale\":250.0, \"start_date\":\"2021-09-01\", \"end_date\":\"2021-09-10\", \"geometry\":{\"type\":\"FeatureCollection\",\"features\":[{\"type\":\"Feature\",\"properties\":{\"id\":1},\"geometry\":{\"type\":\"Polygon\",\"coordinates\":[[[19.51171875,4.214943141390651],[18.28125,-4.740675384778361],[26.894531249999996,-4.565473550710278],[27.24609375,1.2303741774326145],[19.51171875,4.214943141390651]]]}}]}}");
        
        
        requestId = sendOperatorRequest(req, oraclePaymentAmount);
            
        emit dataRequestSent(requestId);
    }
    
    
    /**
     * @dev Callback function - This gets called by the Oracle Contract when the Oracle Node passes data back to the Oracle Contract
     * The function will take the rainfall given by the Oracle and updated the Inusrance Contract state
     */ 
    function checkRainfallCallBack(bytes32 _requestId, int256 _rainfall, string calldata cidValue) public recordChainlinkFulfillment(_requestId) onContractActive() callFrequencyOncePerDay()  {
        //set current temperature to value returned from Oracle, and store date this was retrieved (to avoid spam and gaming the contract)
       currentRainfallList[dataRequestsSent] = _rainfall; 
       dataRequestsSent = dataRequestsSent + 1;
       
       //set current rainfall to average of both values
       if (dataRequestsSent > 1) {
          currentRainfall = median(currentRainfallList, currentRainfallList.length);
          //(currentRainfallList[0] + currentRainfallList[1]) / 2;
          currentRainfallDateChecked =  block.timestamp;
          requestCount +=1;
          cid = cidValue;
          cids[total_oracle_calls] = cid;
          total_oracle_calls = total_oracle_calls + 1;
        
          //check if payout conditions have been met, if so call payoutcontract, which should also end/kill contract at the end
          if (currentRainfall == 0 ) { //temp threshold has been  met, add a day of over threshold
              daysWithoutRain += 1;
          } else {
              //there was rain today, so reset daysWithoutRain parameter 
              daysWithoutRain = 0;
              emit ranfallThresholdReset(currentRainfall);
          }
       
          if (daysWithoutRain >= DROUGHT_DAYS_THRESDHOLD) {  // day threshold has been met
              //need to pay client out insurance amount
              payOutContract();
          }
       }
       
       emit dataReceived(_rainfall);
        
    }
    
    
    /**
     * @dev Insurance conditions have been met, do payout of total cover amount to client
     */ 
    function payOutContract() private onContractActive()  {
        
        //Transfer agreed amount to client
        client.transfer(address(this).balance);
        
        //Transfer any remaining funds (premium) back to Insurer
        LinkTokenInterface link = LinkTokenInterface(chainlinkTokenAddress());
        require(link.transfer(insurer, link.balanceOf(address(this))), "Unable to transfer");
        
        emit contractPaidOut(block.timestamp, payoutValue, currentRainfall);
        
        //now that amount has been transferred, can end the contract 
        //mark contract as ended, so no future calls can be done
        contractActive = false;
        contractPaid = true;
    
    }  
    
    /**
     * @dev Insurance conditions have not been met, and contract expired, end contract and return funds
     */ 
    function checkEndContract() private onContractEnded()   {
        //Insurer needs to have performed at least 1 weather call per day to be eligible to retrieve funds back.
        //We will allow for 1 missed weather call to account for unexpected issues on a given day.
        if (requestCount >= (duration / DAY_IN_SECONDS) - 2) {
            //return funds back to insurance provider then end/kill the contract
            insurer.transfer(address(this).balance);
        } else { //insurer hasn't done the minimum number of data requests, client is eligible to receive his premium back
            // need to use ETH/USD price feed to calculate ETH amount
            client.transfer(premium / uint(getLatestPrice()));
            insurer.transfer(address(this).balance);
        }
        
        //transfer any remaining LINK tokens back to the insurer
        LinkTokenInterface link = LinkTokenInterface(chainlinkTokenAddress());
        require(link.transfer(insurer, link.balanceOf(address(this))), "Unable to transfer remaining LINK tokens");
        
        //mark contract as ended, so no future state changes can occur on the contract
        contractActive = false;
        emit contractEnded(block.timestamp, address(this).balance);
    }
    
    /**
     * Returns the latest price
     */
    function getLatestPrice() public view returns (int) {
        (
            uint80 roundID, 
            int price,
            uint startedAt,
            uint timeStamp,
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();
        // If the round is not complete yet, timestamp is 0
        require(timeStamp > 0, "Round not complete");
        return price;
    }
    
    
    /**
     * @dev Get the balance of the contract
     */ 
    function getContractBalance() external view returns (uint) {
        return address(this).balance;
    } 
    
    /**
     * @dev Get the Crop Location
     */ 
    // function getLocation() external view returns (string) {
    //     return cropLocation;
    // } 
    
    
    /**
     * @dev Get the Total Cover
     */ 
    function getPayoutValue() external view returns (uint) {
        return payoutValue;
    } 
    
    
    /**
     * @dev Get the Premium paid
     */ 
    function getPremium() external view returns (uint) {
        return premium;
    } 
    
    /**
     * @dev Get the status of the contract
     */ 
    function getContractStatus() external view returns (bool) {
        return contractActive;
    }
    
    /**
     * @dev Get whether the contract has been paid out or not
     */ 
    function getContractPaid() external view returns (bool) {
        return contractPaid;
    }
    
    
    /**
     * @dev Get the current recorded rainfall for the contract
     */ 
    function getCurrentRainfall() external view returns (int) {
        return currentRainfall;
    }
    
    /**
     * @dev Get the recorded number of days without rain
     */ 
    function getDaysWithoutRain() external view returns (uint) {
        return daysWithoutRain;
    }
    
    /**
     * @dev Get the count of requests that has occured for the Insurance Contract
     */ 
    function getRequestCount() external view returns (uint) {
        return requestCount;
    }
    
    /**
     * @dev Get the last time that the rainfall was checked for the contract
     */ 
    function getCurrentRainfallDateChecked() external view returns (uint) {
        return currentRainfallDateChecked;
    }
    
    /**
     * @dev Get the contract duration
     */ 
    function getDuration() external view returns (uint) {
        return duration;
    }
    
    /**
     * @dev Get the contract start date
     */ 
    function getContractStartDate() external view returns (uint) {
        return startDate;
    }
    
    /**
     * @dev Get the current date/time according to the blockchain
     */ 
    function getNow() external view returns (uint) {
        return block.timestamp;
    }
    
    /**
     * @dev Get address of the chainlink token
     */ 
    function getChainlinkToken() public view returns (address) {
        return chainlinkTokenAddress();
    }
    
    /**
     * @dev Helper function for converting a string to a bytes32 object
     */ 
    function stringToBytes32(string memory source) private pure returns (bytes32 result) {
        bytes memory tempEmptyStringTest = bytes(source);
        if (tempEmptyStringTest.length == 0) {
         return 0x0;
        }

        assembly { // solhint-disable-line no-inline-assembly
        result := mload(add(source, 32))
        }
    }
    
    
    
    mapping(uint256 => string) cids;

    function getCid(uint256 index)
            public
            view
            returns (string memory)
    {
            return cids[index];
    }


    function swap(int256[2] memory array, uint256 i, uint256 j) internal pure {
        (array[i], array[j]) = (array[j], array[i]);
    }

    function sort(int256[2] memory array, uint256 begin, uint256 end) internal pure {
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
    function median(int256[2] memory array, uint256 length) internal pure returns(int256) {
        sort(array, 0, length);
        return length % 2 == 0 ? (array[length/2-1] + array[length/2]) / 2 : array[length/2];
    }

}