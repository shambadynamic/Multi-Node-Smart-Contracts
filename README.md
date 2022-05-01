# Multi-Node-Smart-Contracts

This GitHub repository contains 3 solidity smart contracts:

1. Solidity Smart Contract interacting with multiple oracle nodes for fetching fire-analysis and detection data, and aggregating the resultant data by calculating the mode of the data returning from all the Chainlink nodes.

2. Solidity Smart Contract interacting with multiple oracle nodes for fetching geostatistical data and aggregating the resultant data by calculating the median of the data returning from all the Chainlink nodes.

3. Solidy Smart Contract based on Parametric Insurance having a factory contract named as InsuranceProvider and a consumer contract named as InsuranceContract, fetching geostatistical data and aggregating the resultant data by calculating the median of the data returning from two separate Chainlink Oracle nodes.