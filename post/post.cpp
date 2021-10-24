

#include"uniqueID.h"
#include <fstream>

using namespace std;


void newPost(int reqID, string post)
{
     int64_t postID =  UploadUniqueId(reqID);
	
	cout << "post id: " << postID <<endl;
	cout << "post" << post  <<endl<<endl;
		
	//TO DO
	//call the text service from grpc call
	//save the post from memcahced or DB

}

string getPost(string postID)
{
	//TO DO
	//get post from memcahced or DB
	//get the url original from the url service
	
}

int main(int argc, char *argv[]) {

	if(argc < 3) {
        printf("You must provide the number of lines and csv file\n");
        exit(0);
    }
	
	int num_lines = 0;
	int lines = 0;
	fstream postfile;


	std::string postdir(argv[1]);
	num_lines = atoi(argv[2]);

  
   postfile.open(argv[1],ios::in); 
   if (postfile.is_open()){  
      string tp;
      while(getline(postfile, tp) && lines < num_lines){ 
		if(tp == "")
		  continue;
	  
		newPost(lines, tp);
		
		 lines++;
      }
      postfile.close(); 
   }

	return 0;
}